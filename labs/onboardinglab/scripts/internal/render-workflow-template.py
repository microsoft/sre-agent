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


def workflow_root(template_path):
    for candidate in (template_path.parent, *template_path.parents):
        if (candidate / "plugin/skills").is_dir():
            return candidate.resolve()
    fail("template must be under a workflow directory containing plugin/skills")


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


def parse_prerequisites(document):
    prerequisites = require_mapping(document.get("prerequisites"), "prerequisites")
    if prerequisites.get("failure_policy") != "fail-deployment":
        fail("prerequisites.failure_policy must be fail-deployment")
    telemetry_minimum = None
    for requirement in prerequisites.get("required", []):
        if isinstance(requirement, dict) and "telemetry_connectors" in requirement:
            telemetry = require_mapping(requirement["telemetry_connectors"], "telemetry_connectors")
            telemetry_minimum = telemetry.get("minimum")
    if not isinstance(telemetry_minimum, int) or telemetry_minimum < 1:
        fail("a positive telemetry_connectors.minimum is required")
    return telemetry_minimum


def parse_agent(custom_agent, template_path, root, handoff_description):
    custom_agent = require_mapping(custom_agent, "custom_agent")
    agent_name = require_name(custom_agent.get("name"), "custom_agent.name")
    action_mode = require_string(custom_agent.get("action_mode"), "custom_agent.action_mode")
    if action_mode not in {"Review", "Autonomous"}:
        fail("custom_agent.action_mode must be Review or Autonomous")

    tool_groups = require_mapping(custom_agent.get("tools"), "custom_agent.tools")
    read_tools = tool_groups.get("read_only", [])
    ask_tools = tool_groups.get("ask_approval", [])
    denied_tools = tool_groups.get("deny", [])
    if not all(
        isinstance(group, list)
        and all(isinstance(item, str) and re.fullmatch(r"[A-Za-z0-9*/-]+", item) for item in group)
        for group in (read_tools, ask_tools, denied_tools)
    ):
        fail("custom agent tool groups must be lists of tool names")
    attached_tools = list(dict.fromkeys(read_tools + ask_tools))
    if set(attached_tools) & set(denied_tools):
        fail("a denied tool cannot also be attached to the custom agent")

    skill_entries = custom_agent.get("skills")
    if not isinstance(skill_entries, list) or not skill_entries:
        fail("custom_agent.skills must be a non-empty list")
    skills = []
    skill_names = []
    for entry in skill_entries:
        entry = require_mapping(entry, "custom_agent.skills entry")
        name = require_name(entry.get("name"), "skill name")
        source = require_string(entry.get("source"), f"source for {name}")
        source_path = (template_path.parent / source).resolve()
        if not source_path.is_file() or root not in source_path.parents:
            fail(f"skill source must be a file under the workflow directory: {source}")
        skill_names.append(name)
        skills.append(read_skill(source_path, name))

    instructions = require_string(custom_agent.get("instructions"), "custom_agent.instructions")
    subagent = {
        "metadata": {"name": agent_name},
        "spec": {
            "instructions": instructions,
            "handoffDescription": handoff_description,
            "handoffs": [],
            "tools": attached_tools,
            "agentType": "Autonomous",
            "temperature": 0.2,
            "enableSkills": True,
            "allowedSkills": skill_names,
        },
    }
    return agent_name, action_mode, denied_tools, skill_names, skills, subagent


def render(template_path):
    template_path = template_path.resolve()
    document = require_mapping(yaml.safe_load(template_path.read_text(encoding="utf-8")), "template")
    scenario_name = require_name(document.get("name"), "name")
    trigger = require_mapping(document.get("trigger"), "trigger")
    trigger_type = trigger.get("type")
    root = workflow_root(template_path)
    telemetry_minimum = parse_prerequisites(document)

    if trigger_type == "incident-platform":
        if trigger.get("platform") != "azure-monitor":
            fail("trigger must use the azure-monitor incident platform")
        handoff_description = "Investigates Azure Monitor incidents using telemetry, Azure state, and source evidence."
    elif trigger_type == "scheduled-task":
        handoff_description = "Runs scheduled ticket reservation health checks and prepares review-gated reports."
    else:
        fail("trigger.type must be incident-platform or scheduled-task")

    agent_name, action_mode, denied_tools, skill_names, skills, subagent = parse_agent(
        document.get("custom_agent"), template_path, root, handoff_description
    )
    extras = {
        "skills": skills,
        "subagents": [subagent],
        "incidentFilters": [],
        "scheduledTasks": [],
        "installerRequirements": {
            "scenarioType": trigger_type,
            "incidentPlatform": "AzMonitor" if trigger_type == "incident-platform" else None,
            "minimumTelemetryConnectors": telemetry_minimum,
            "workflowName": scenario_name,
            "customAgentName": agent_name,
            "skillNames": skill_names,
            "deniedTools": denied_tools,
        },
    }

    if trigger_type == "incident-platform":
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
        extras["incidentFilters"].append({
            "metadata": {"name": scenario_name},
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
        })
    else:
        description = require_string(trigger.get("description"), "trigger.description")
        schedule = require_string(trigger.get("schedule"), "trigger.schedule")
        if len(schedule.split()) != 5:
            fail("trigger.schedule must be a five-field cron expression")
        if trigger.get("enabled") is not True:
            fail("trigger.enabled must be true for the onboarding lab")
        if action_mode != "Review" or require_string(trigger.get("action_mode"), "trigger.action_mode") != "Review":
            fail("scheduled task action_mode must be Review")
        handling_agent = require_name(trigger.get("handling_agent"), "trigger.handling_agent")
        if handling_agent != agent_name:
            fail("trigger.handling_agent must match custom_agent.name")
        prompt = require_string(trigger.get("prompt"), "trigger.prompt")
        extras["scheduledTasks"].append({
            "metadata": {"name": scenario_name},
            "spec": {
                "description": description,
                "schedule": schedule,
                "prompt": prompt,
                "enabled": True,
                "mode": "Review",
                "handlingAgent": agent_name,
            },
        })
        extras["installerRequirements"].update({
            "scheduledTaskName": scenario_name,
            "scheduledTaskSchedule": schedule,
            "scheduledTaskAgentName": agent_name,
        })

    return extras


def main():
    parser = argparse.ArgumentParser(description="Render one onboarding scenario template to SRE Agent extras JSON.")
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    template_path = args.template.resolve()
    if not template_path.is_file():
        fail(f"template not found: {template_path}")
    args.output.write_text(json.dumps(render(template_path), indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
