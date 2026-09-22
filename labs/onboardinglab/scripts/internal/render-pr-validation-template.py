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
    trigger_name = require_name(document.get("name"), "name")
    trigger = require_mapping(document.get("trigger"), "trigger")
    if trigger.get("type") != "http-trigger":
        fail("trigger.type must be http-trigger")
    description = require_string(trigger.get("description"), "trigger.description")
    prompt = require_string(trigger.get("prompt"), "trigger.prompt")
    mode = require_string(trigger.get("action_mode"), "trigger.action_mode")
    if mode != "Review":
        fail("trigger.action_mode must be Review")

    agent = require_mapping(document.get("custom_agent"), "custom_agent")
    agent_name = require_name(agent.get("name"), "custom_agent.name")
    handling_agent = require_name(trigger.get("handling_agent"), "trigger.handling_agent")
    if handling_agent != agent_name:
        fail("trigger.handling_agent must match custom_agent.name")
    if require_string(agent.get("action_mode"), "custom_agent.action_mode") != "Review":
        fail("custom_agent.action_mode must be Review")

    tool_groups = require_mapping(agent.get("tools"), "custom_agent.tools")
    read_tools = tool_groups.get("read_only", [])
    ask_tools = tool_groups.get("ask_approval", [])
    denied_tools = tool_groups.get("deny", [])
    if not all(isinstance(group, list) and all(isinstance(item, str) for item in group)
               for group in (read_tools, ask_tools, denied_tools)):
        fail("custom agent tool groups must be lists of tool names")
    attached_tools = list(dict.fromkeys(read_tools + ask_tools))
    if set(attached_tools) & set(denied_tools):
        fail("a denied tool cannot also be attached to the custom agent")

    skill_entries = agent.get("skills", [])
    if not isinstance(skill_entries, list) or len(skill_entries) != 1:
        fail("custom_agent.skills must contain exactly one skill")
    skill_entry = require_mapping(skill_entries[0], "custom_agent.skills entry")
    skill_name = require_name(skill_entry.get("name"), "skill name")
    skill_source = require_string(skill_entry.get("source"), f"source for {skill_name}")
    skill_path = (template_path.parent / skill_source).resolve()
    workflow_root = template_path.parent.parent.resolve()
    if not skill_path.is_file() or workflow_root not in skill_path.parents:
        fail(f"skill source must be a file under the workflow directory: {skill_source}")

    instructions = require_string(agent.get("instructions"), "custom_agent.instructions")
    return {
        "skills": [read_skill(skill_path, skill_name)],
        "subagents": [{
            "metadata": {"name": agent_name},
            "spec": {
                "instructions": instructions,
                "handoffDescription": "Validates GitHub pull requests using repository evidence and read-only production context.",
                "handoffs": [],
                "tools": attached_tools,
                "agentType": "Autonomous",
                "temperature": 0.2,
                "enableSkills": True,
                "allowedSkills": [skill_name],
            },
        }],
        "httpTriggers": [{
            "name": trigger_name,
            "spec": {
                "description": description,
                "agentPrompt": prompt,
                "agent": handling_agent,
                "agentMode": mode,
            },
        }],
        "enableWebhookBridge": True,
        "installerRequirements": {
            "triggerName": trigger_name,
            "agentName": agent_name,
            "skillName": skill_name,
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Render the onboarding PR-validation template.")
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    template_path = args.template.resolve()
    if not template_path.is_file():
        fail(f"template not found: {template_path}")
    args.output.write_text(json.dumps(render(template_path), indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()