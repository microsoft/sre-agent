#!/usr/bin/env python3

import argparse
import json
import re
from pathlib import Path

import yaml


def fail(message):
    raise SystemExit(f"Error: {message}")


def require_mapping(value, label):
    if not isinstance(value, dict):
        fail(f"{label} must be a mapping")
    return value


def require_string(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value.strip()


def require_name(value, label):
    value = require_string(value, label)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", value):
        fail(f"{label} must contain only letters, numbers, and hyphens")
    return value


def tool_names(value):
    if not isinstance(value, list) or not all(
            isinstance(item, str) and re.fullmatch(r"[A-Za-z0-9*/-]+", item) for item in value):
        fail("custom agent tool groups must be lists of tool names")
    return list(value)


def read_skill(path, expected_name):
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\A---\s*\n(.*?)\n---\s*\n", text, re.DOTALL)
    if not match:
        fail(f"skill {path} is missing YAML frontmatter")
    metadata = require_mapping(yaml.safe_load(match.group(1)), f"skill metadata in {path}")
    if metadata.get("name") != expected_name:
        fail(f"skill {path} name does not match {expected_name}")
    description = require_string(metadata.get("description"), f"description for {expected_name}")
    return {
        "metadata": {
            "name": expected_name,
            "description": description,
            "spec": {"tools": []},
        },
        "skillContent": text,
        "additionalFiles": [],
    }


def github_repository(value):
    value = require_string(value, "github repository")
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", value):
        fail("github repository must be https://github.com/owner/repository without a trailing slash")
    if value.rsplit("/", 1)[-1] in {".", ".."}:
        fail("github repository must name a repository")
    return value.removesuffix(".git")


def render(template_path, *, enable_source_code=False, enable_github_issues=False,
           enable_email=False, github_repo=None, email_recipients=None):
    if enable_source_code or enable_github_issues:
        github_repo = github_repository(github_repo)
    elif github_repo:
        fail("github repository requires --enable-source-code or --enable-github-issues")
    if enable_email:
        recipients = require_string(email_recipients, "email recipients").split(",")
        if any(not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", item.strip())
               for item in recipients):
            fail("email recipients must be a comma-separated list of email addresses")
        email_recipients = ",".join(dict.fromkeys(item.strip() for item in recipients))
    elif email_recipients:
        fail("email recipients require --enable-email")
    document = require_mapping(yaml.safe_load(template_path.read_text(encoding="utf-8")), "template")
    workflow_name = require_name(document.get("name"), "name")
    trigger = require_mapping(document.get("trigger"), "trigger")
    if trigger.get("type") != "incident-platform" or trigger.get("platform") != "azure-monitor":
        fail("trigger must use the azure-monitor incident platform")

    filters = require_mapping(trigger.get("filters"), "trigger.filters")
    severities = filters.get("severities")
    if not isinstance(severities, list) or not severities:
        fail("trigger.filters.severities must be a non-empty list")
    if any(value not in {f"Sev{index}" for index in range(5)} for value in severities):
        fail("trigger severities must be Sev0 through Sev4")
    title_contains = require_string(filters.get("title_contains"), "trigger.filters.title_contains")
    merge_window = require_string(filters.get("merge_window"), "trigger.filters.merge_window")
    merge_match = re.fullmatch(r"PT([1-9][0-9]*)H", merge_window)
    if not merge_match:
        fail("merge_window must be an ISO 8601 whole-hour duration such as PT3H")

    prerequisites = require_mapping(document.get("prerequisites"), "prerequisites")
    if prerequisites.get("failure_policy") != "fail-deployment":
        fail("prerequisites.failure_policy must be fail-deployment")
    telemetry_minimum = None
    for requirement in prerequisites.get("required", []):
        if isinstance(requirement, dict) and "telemetry_connectors" in requirement:
            telemetry = require_mapping(requirement["telemetry_connectors"], "telemetry_connectors")
            telemetry_minimum = telemetry.get("minimum")
    if type(telemetry_minimum) is not int or telemetry_minimum < 1:
        fail("a positive telemetry_connectors.minimum is required")

    custom_agent = require_mapping(document.get("custom_agent"), "custom_agent")
    agent_name = require_name(custom_agent.get("name"), "custom_agent.name")
    action_mode = require_string(custom_agent.get("action_mode"), "custom_agent.action_mode")
    if action_mode != "Review":
        fail("custom_agent.action_mode must be Review for the onboarding lab")

    tool_groups = require_mapping(custom_agent.get("tools"), "custom_agent.tools")
    read_tools = tool_names(tool_groups.get("read_only", []))
    ask_tools = tool_names(tool_groups.get("ask_approval", []))
    denied_tools = tool_names(tool_groups.get("deny", []))
    skill_entries = custom_agent.get("skills")
    if not isinstance(skill_entries, list) or not skill_entries:
        fail("custom_agent.skills must be a non-empty list")
    skill_entries = list(skill_entries)
    selected = {"source_code": enable_source_code, "github_issues": enable_github_issues, "email": enable_email}
    optional = require_mapping(custom_agent.get("optional_capabilities", {}), "custom_agent.optional_capabilities")
    for name, enabled in selected.items():
        if enabled:
            capability = require_mapping(optional.get(name), f"optional capability {name}")
            read_tools.extend(tool_names(capability.get("read_only", [])))
            ask_tools.extend(tool_names(capability.get("ask_approval", [])))
            capability_skills = capability.get("skills", [])
            if not isinstance(capability_skills, list):
                fail(f"optional capability {name} skills must be a list")
            skill_entries.extend(capability_skills)
    attached_tools = list(dict.fromkeys(read_tools + ask_tools))
    if set(attached_tools) & set(denied_tools):
        fail("a denied tool cannot also be attached to the custom agent")

    skills = []
    skill_names = []
    for entry in skill_entries:
        entry = require_mapping(entry, "custom_agent.skills entry")
        name = require_name(entry.get("name"), "skill name")
        if name in skill_names:
            fail(f"duplicate skill name: {name}")
        source = require_string(entry.get("source"), f"source for {name}")
        source_path = (template_path.parent / source).resolve()
        if not source_path.is_file() or template_path.parent.resolve() not in source_path.parents:
            fail(f"skill source must be a file under the workflow directory: {source}")
        skill_names.append(name)
        skills.append(read_skill(source_path, name))

    instructions = require_string(custom_agent.get("instructions"), "custom_agent.instructions")
    if github_repo:
        instructions += f"\n\nTrusted setup GitHub repository: {github_repo}."
    if enable_email:
        instructions += f"\n\nTrusted setup email connector: office365. Approved destination scope: {email_recipients}. Obtain approval before each send."
    extras = {
        "skills": skills,
        "subagents": [{
            "metadata": {"name": agent_name},
            "spec": {
                "instructions": instructions,
                "handoffDescription": "Investigates Azure Monitor incidents using telemetry, Azure state, and optional source evidence.",
                "handoffs": [],
                "tools": attached_tools,
                "agentType": "Autonomous",
                "temperature": 0.2,
                "enableSkills": True,
                "allowedSkills": skill_names,
            },
        }],
        "incidentFilters": [{
            "metadata": {"name": workflow_name},
            "spec": {
                "incidentPlatform": "AzMonitor",
                "isEnabled": True,
                "priorities": severities,
                "titleContains": title_contains,
                "handlingAgent": agent_name,
                "agentMode": action_mode,
                "maxAutomatedInvestigationAttempts": 3,
                "mergeEnabled": True,
                "mergeWindowHours": int(merge_match.group(1)),
            },
        }],
        "installerRequirements": {
            "incidentPlatform": "AzMonitor",
            "minimumTelemetryConnectors": telemetry_minimum,
            "workflowName": workflow_name,
            "customAgentName": agent_name,
            "skillNames": skill_names,
            "deniedTools": denied_tools,
            "askApprovalTools": ask_tools,
            "capabilities": selected,
            "githubRepository": github_repo,
            "emailRecipients": email_recipients,
        },
    }
    return extras


def resource_list(value, label):
    if isinstance(value, dict):
        value = value.get("value", value.get("values"))
    if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
        fail(f"{label} must contain a resource list")
    return value


def validate_prerequisites(extras, state):
    state = require_mapping(state, "prerequisite state")
    agent = require_mapping(state.get("agent"), "agent")
    properties = require_mapping(agent.get("properties"), "agent.properties")
    requirements = extras["installerRequirements"]
    if properties.get("incidentManagementConfiguration", {}).get("type") != requirements["incidentPlatform"]:
        fail("agent must use the AzMonitor incident platform")
    if not isinstance(properties.get("agentEndpoint"), str) or not properties["agentEndpoint"].startswith("https://"):
        fail("agent endpoint is unavailable")
    connectors = resource_list(state.get("connectors"), "connectors")
    telemetry_tools = {
        "AppInsights": "QueryAppInsightsUsingAppId",
        "LogAnalytics": "QueryLogAnalyticsByWorkspaceId",
    }
    healthy = [item.get("properties", {}) for item in connectors
               if item.get("properties", {}).get("dataConnectorType") in telemetry_tools
               and item.get("properties", {}).get("provisioningState") in {"Succeeded", "Running"}]
    if len(healthy) < requirements["minimumTelemetryConnectors"]:
        fail(f"found {len(healthy)} healthy telemetry connectors; expected at least {requirements['minimumTelemetryConnectors']}")
    tools = extras["subagents"][0]["spec"]["tools"]
    extras["subagents"][0]["spec"]["tools"] = list(dict.fromkeys(
        tools + [telemetry_tools[item["dataConnectorType"]] for item in healthy]))
    capabilities = requirements["capabilities"]
    if capabilities["source_code"] or capabilities["github_issues"]:
        repos = resource_list(state.get("repos"), "repos")
        target = requirements["githubRepository"].lower()
        matches = [item for item in repos
                   if str(item.get("properties", item).get("url", "")).removesuffix(".git").rstrip("/").lower() == target]
        if len(matches) != 1:
            fail("selected GitHub repository is not uniquely configured on the agent; complete optional repository setup")
        domains = resource_list(state.get("githubDomains"), "github domains")
        if not any(item.get("name") in {"github.com", "github_com"} and item.get("isHealthy") is True for item in domains):
            fail("github.com authentication is not healthy; complete optional GitHub authorization")
    if capabilities["email"]:
        managed = resource_list(state.get("managedConnectors"), "managed connectors")
        if not any(item.get("name") == "office365" for item in managed):
            fail("office365 managed connector is missing; complete optional email setup")
        connection = require_mapping(state.get("emailConnection"), "office365 connection")
        properties = require_mapping(connection.get("properties"), "office365 connection properties")
        statuses = properties.get("statuses", [])
        status = properties.get("overallStatus")
        if not status and statuses:
            status = statuses[0].get("status")
        if status != "Connected":
            fail("office365 connection is not Connected; complete Outlook consent before enabling email")
    return extras


def main():
    parser = argparse.ArgumentParser(description="Render an onboarding workflow template to SRE Agent extras JSON.")
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--enable-source-code", action="store_true")
    parser.add_argument("--enable-github-issues", action="store_true")
    parser.add_argument("--enable-email", action="store_true")
    parser.add_argument("--github-repository")
    parser.add_argument("--email-recipients")
    parser.add_argument("--prerequisite-state", type=Path,
                        help="Validate a read-only agent/connector snapshot and attach its healthy telemetry tools.")
    args = parser.parse_args()
    template_path = args.template.resolve()
    if not template_path.is_file():
        fail(f"template not found: {template_path}")
    extras = render(template_path, enable_source_code=args.enable_source_code,
                    enable_github_issues=args.enable_github_issues, enable_email=args.enable_email,
                    github_repo=args.github_repository, email_recipients=args.email_recipients)
    if args.prerequisite_state:
        extras = validate_prerequisites(extras, json.loads(args.prerequisite_state.read_text(encoding="utf-8-sig")))
    args.output.write_text(json.dumps(extras, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()