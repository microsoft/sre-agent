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


def render(template_path):
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
    if not isinstance(telemetry_minimum, int) or telemetry_minimum < 1:
        fail("a positive telemetry_connectors.minimum is required")

    custom_agent = require_mapping(document.get("custom_agent"), "custom_agent")
    agent_name = require_name(custom_agent.get("name"), "custom_agent.name")
    action_mode = require_string(custom_agent.get("action_mode"), "custom_agent.action_mode")
    if action_mode not in {"Review", "Autonomous"}:
        fail("custom_agent.action_mode must be Review or Autonomous")

    tool_groups = require_mapping(custom_agent.get("tools"), "custom_agent.tools")
    read_tools = tool_groups.get("read_only", [])
    ask_tools = tool_groups.get("ask_approval", [])
    denied_tools = tool_groups.get("deny", [])
    if not all(isinstance(group, list) and all(isinstance(item, str) and re.fullmatch(r"[A-Za-z0-9*/-]+", item) for item in group)
               for group in (read_tools, ask_tools, denied_tools)):
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
        if not source_path.is_file() or template_path.parent.resolve() not in source_path.parents:
            fail(f"skill source must be a file under the workflow directory: {source}")
        skill_names.append(name)
        skills.append(read_skill(source_path, name))

    scheduled_task = require_mapping(document.get("scheduled_task"), "scheduled_task")
    scheduled_task_name = require_name(scheduled_task.get("name"), "scheduled_task.name")
    scheduled_task_description = require_string(
        scheduled_task.get("description"), "scheduled_task.description"
    )
    scheduled_task_schedule = require_string(scheduled_task.get("schedule"), "scheduled_task.schedule")
    if len(scheduled_task_schedule.split()) != 5:
        fail("scheduled_task.schedule must be a five-field cron expression")
    if scheduled_task.get("enabled") is not False:
        fail("scheduled_task.enabled must be false for the onboarding lab")
    scheduled_task_mode = require_string(scheduled_task.get("action_mode"), "scheduled_task.action_mode")
    if scheduled_task_mode != "Review":
        fail("scheduled_task.action_mode must be Review")
    scheduled_task_prompt = require_string(scheduled_task.get("prompt"), "scheduled_task.prompt")
    scheduled_task_skill = require_mapping(scheduled_task.get("skill"), "scheduled_task.skill")
    scheduled_task_skill_name = require_name(scheduled_task_skill.get("name"), "scheduled_task.skill.name")
    scheduled_task_skill_source = require_string(
        scheduled_task_skill.get("source"), f"source for {scheduled_task_skill_name}"
    )
    scheduled_task_skill_path = (template_path.parent / scheduled_task_skill_source).resolve()
    if not scheduled_task_skill_path.is_file() or template_path.parent.resolve() not in scheduled_task_skill_path.parents:
        fail(f"skill source must be a file under the workflow directory: {scheduled_task_skill_source}")
    if scheduled_task_skill_name in skill_names:
        fail(f"duplicate skill name: {scheduled_task_skill_name}")
    skills.append(read_skill(scheduled_task_skill_path, scheduled_task_skill_name))

    instructions = require_string(custom_agent.get("instructions"), "custom_agent.instructions")
    extras = {
        "skills": skills,
        "subagents": [{
            "metadata": {"name": agent_name},
            "spec": {
                "instructions": instructions,
                "handoffDescription": "Investigates Azure Monitor incidents using telemetry, Azure state, and source evidence.",
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
        "scheduledTasks": [{
            "metadata": {"name": scheduled_task_name},
            "spec": {
                "description": scheduled_task_description,
                "schedule": scheduled_task_schedule,
                "prompt": scheduled_task_prompt,
                "enabled": False,
                "mode": scheduled_task_mode,
            },
        }],
        "installerRequirements": {
            "incidentPlatform": "AzMonitor",
            "minimumTelemetryConnectors": telemetry_minimum,
            "workflowName": workflow_name,
            "customAgentName": agent_name,
            "skillNames": skill_names + [scheduled_task_skill_name],
            "deniedTools": denied_tools,
            "askApprovalTools": ask_tools,
            "scheduledTaskName": scheduled_task_name,
            "scheduledTaskSchedule": scheduled_task_schedule,
        },
    }
    return extras


def main():
    parser = argparse.ArgumentParser(description="Render an onboarding workflow template to SRE Agent extras JSON.")
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    template_path = args.template.resolve()
    if not template_path.is_file():
        fail(f"template not found: {template_path}")
    extras = render(template_path)
    args.output.write_text(json.dumps(extras, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()