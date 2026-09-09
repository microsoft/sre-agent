#!/usr/bin/env python3
import json
import sys


def first_object(pairs):
    result = {}
    for key, value in pairs:
        if key not in result:
            result[key] = value
    return result


allowed_tools = {
    "read_skill_file",
    "ReadFile",
    "ListDir",
    "FileSearch",
    "GrepSearch",
    "system-mcp-monitor_monitor_resource_log_query",
    "system-mcp-monitor_monitor_metrics_query",
}

try:
    context = json.load(sys.stdin, object_pairs_hook=first_object)
except (json.JSONDecodeError, UnicodeError):
    context = None

tool_name = context.get("tool_name") if isinstance(context, dict) else None
if isinstance(tool_name, str) and tool_name in allowed_tools:
    print(json.dumps({"ok": True}))
else:
    print(json.dumps({
        "ok": False,
        "reason": "Read-only specialist guard: tool is outside this agent's permitted read operations.",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
        },
    }))
