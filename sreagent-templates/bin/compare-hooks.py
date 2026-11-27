#!/usr/bin/env python3
"""Compare effective local hooks with deployed definitions."""

import hashlib
import json
from pathlib import Path
import sys


def index_hooks(items):
    if not isinstance(items, list):
        raise ValueError("Expected a hook array")
    indexed = {}
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str) or not item["name"]:
            raise ValueError("Expected named hook objects")
        if item["name"] in indexed:
            raise ValueError("Duplicate hook name: " + item["name"])
        properties = item.get("properties")
        if not isinstance(properties, dict) or not isinstance(properties.get("hook"), dict):
            raise ValueError("Expected hook properties and definition: " + item["name"])
        indexed[item["name"]] = properties
    return indexed


def normalize(value):
    if isinstance(value, str):
        return value.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n")
    if isinstance(value, dict):
        return {key: normalize(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value


def fingerprint(properties, desired):
    hook = properties["hook"]
    if not isinstance(properties.get("eventType"), str) or not isinstance(hook.get("type"), str):
        raise ValueError("Expected hook eventType and type strings")
    keys = set(desired["hook"]) | {"type", "matcher", "script", "command", "prompt"}
    definition = {}
    for key in keys:
        value = hook.get(key)
        if key in {"type", "failMode"} and isinstance(value, str):
            value = value.lower()
        if key in {"script", "command", "prompt"} and value is None:
            value = ""
        definition[key] = value
    payload = {
        "eventType": properties["eventType"].lower(),
        "activationMode": properties.get("activationMode", "always").lower(),
        "hook": normalize(definition),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def compare(expected, deployed):
    if not isinstance(expected, dict) or "hooks" not in expected:
        raise ValueError("Expected assembled extras with a hooks array")
    local = index_hooks(expected["hooks"])
    if isinstance(deployed, dict):
        if "value" not in deployed:
            raise ValueError("Expected deployed hooks array or value envelope")
        deployed = deployed["value"]
    remote = index_hooks(deployed)
    rows = []
    for name, desired in local.items():
        action = "CREATE" if name not in remote else (
            "MATCH" if fingerprint(desired, desired) == fingerprint(remote[name], desired) else "UPDATE"
        )
        rows.append({"name": name, "action": action})
    rows.extend({"name": name, "action": "ORPHAN"} for name in remote if name not in local)
    return rows


if __name__ == "__main__":
    try:
        expected, deployed = (
            json.loads(Path(path).read_text(encoding="utf-8-sig")) for path in sys.argv[1:]
        )
        print(json.dumps(compare(expected, deployed)))
    except (ValueError, OSError, TypeError, AttributeError) as error:
        print("Hook comparison failed: " + str(error), file=sys.stderr)
        sys.exit(3)
