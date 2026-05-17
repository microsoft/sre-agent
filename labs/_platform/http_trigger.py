#!/usr/bin/env python3
"""
SRE Agent HTTP Trigger registration helper.

Reusable across labs. Wraps the (currently CLI-less) REST API at
  POST /api/v1/httptriggers/create
  POST /api/v1/httptriggers/{id}/enable
  GET  /api/v1/httptriggers/{id}
  ...

Authentication: bearer token for resource 'https://azuresre.ai' (same as srectl).

CLI:
  python http_trigger.py create-and-enable \
      --endpoint https://<your-agent>.azuresre.ai \
      --name my-trigger \
      --agent incident-handler \
      --prompt "Investigate the incoming alert payload." \
      [--mode autonomous|review|readonly] \
      [--description "..."]

Prints JSON to stdout: { "triggerId": "...", "triggerUrl": "..." }
Exit 0 on success, 1 on failure.

Idempotent: if a trigger with the same --name already exists, reuses it
(GETs the URL via /enable which is idempotent and returns the existing URL).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


def _az_token(resource: str = "https://azuresre.ai") -> str:
    """Acquire an AAD bearer token for the SRE Agent resource via az CLI."""
    try:
        out = subprocess.run(
            ["az", "account", "get-access-token", "--resource", resource,
             "--query", "accessToken", "-o", "tsv"],
            capture_output=True, text=True, timeout=60, check=True, shell=False,
        )
        token = out.stdout.strip()
        if not token:
            raise RuntimeError("empty token from az")
        return token
    except FileNotFoundError:
        # Windows: az may need shell
        out = subprocess.run(
            'az account get-access-token --resource "%s" --query accessToken -o tsv' % resource,
            capture_output=True, text=True, timeout=60, check=True, shell=True,
        )
        return out.stdout.strip()


def _request(method: str, url: str, token: str, body: dict | None = None, timeout: int = 60) -> dict:
    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return {"_raw": raw}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code} {e.reason} on {method} {url}: {detail[:500]}") from None


def list_triggers(endpoint: str, token: str) -> list[dict]:
    out = _request("GET", f"{endpoint.rstrip('/')}/api/v1/httptriggers", token)
    if isinstance(out, list):
        return out
    return out.get("items") or out.get("triggers") or []


def find_by_name(endpoint: str, token: str, name: str) -> dict | None:
    for t in list_triggers(endpoint, token):
        if t.get("name") == name:
            return t
    return None


def create_trigger(endpoint: str, token: str, *, name: str, agent: str,
                   prompt: str, mode: str = "autonomous",
                   description: str = "") -> dict:
    body = {
        "name": name,
        "agent": agent,
        "agentPrompt": prompt,
        "agentMode": mode,
    }
    if description:
        body["description"] = description
    return _request(
        "POST",
        f"{endpoint.rstrip('/')}/api/v1/httptriggers/create",
        token,
        body=body,
    )


def enable_trigger(endpoint: str, token: str, trigger_id: str) -> dict:
    return _request(
        "POST",
        f"{endpoint.rstrip('/')}/api/v1/httptriggers/{trigger_id}/enable",
        token,
        body={},
    )


def get_trigger(endpoint: str, token: str, trigger_id: str) -> dict:
    return _request(
        "GET",
        f"{endpoint.rstrip('/')}/api/v1/httptriggers/{trigger_id}",
        token,
    )


def create_and_enable(endpoint: str, *, name: str, agent: str, prompt: str,
                      mode: str = "autonomous", description: str = "") -> dict:
    """Idempotent: returns {triggerId, triggerUrl}."""
    token = _az_token()
    existing = find_by_name(endpoint, token, name)
    if existing:
        trigger_id = existing.get("triggerId") or existing.get("id")
        url = existing.get("triggerUrl") or existing.get("url")
        if not url:
            enabled = enable_trigger(endpoint, token, trigger_id)
            url = enabled.get("triggerUrl") or enabled.get("url")
        return {"triggerId": trigger_id, "triggerUrl": url, "reused": True}

    created = create_trigger(
        endpoint, token,
        name=name, agent=agent, prompt=prompt,
        mode=mode, description=description,
    )
    trigger_id = created.get("triggerId") or created.get("id")
    if not trigger_id:
        raise RuntimeError(f"create returned no triggerId: {created!r}")

    # Small delay — server may need a tick before enable can mint URL
    time.sleep(1.0)
    enabled = enable_trigger(endpoint, token, trigger_id)
    url = enabled.get("triggerUrl") or enabled.get("url") or created.get("triggerUrl")
    if not url:
        # Last resort: GET it
        info = get_trigger(endpoint, token, trigger_id)
        url = info.get("triggerUrl") or info.get("url")
    return {"triggerId": trigger_id, "triggerUrl": url, "reused": False}


def _cli() -> int:
    p = argparse.ArgumentParser(description="SRE Agent HTTP trigger helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    cae = sub.add_parser("create-and-enable", help="Create (or reuse) and enable a trigger; print {triggerId, triggerUrl}")
    cae.add_argument("--endpoint", required=True, help="SRE Agent endpoint, e.g. https://<name>.azuresre.ai")
    cae.add_argument("--name", required=True)
    cae.add_argument("--agent", required=True, help="Sub-agent metadata.name to invoke")
    cae.add_argument("--prompt", required=True, help="Default agentPrompt for this trigger")
    cae.add_argument("--mode", default="autonomous", choices=["autonomous", "review", "readonly"])
    cae.add_argument("--description", default="")

    lst = sub.add_parser("list", help="List triggers")
    lst.add_argument("--endpoint", required=True)

    args = p.parse_args()

    endpoint = (args.endpoint or os.environ.get("SRE_AGENT_ENDPOINT", "")).strip()
    if not endpoint:
        print("error: --endpoint or $SRE_AGENT_ENDPOINT required", file=sys.stderr)
        return 2

    try:
        if args.cmd == "create-and-enable":
            res = create_and_enable(
                endpoint,
                name=args.name, agent=args.agent, prompt=args.prompt,
                mode=args.mode, description=args.description,
            )
            print(json.dumps(res))
            return 0 if res.get("triggerUrl") else 1
        if args.cmd == "list":
            token = _az_token()
            print(json.dumps(list_triggers(endpoint, token), indent=2))
            return 0
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(_cli())
