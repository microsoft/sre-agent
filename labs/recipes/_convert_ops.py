#!/usr/bin/env python3
"""Convert labs/zava-power/sre-config/* -> recipes/azmon-aca-servicenow-zavapower-ops/.

Re-runnable. Idempotent. Reads the live lab and emits files in the recipe shape
that coreai-microsoft/sreagent-templates expects.

Usage:
    python labs/recipes/_convert_ops.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("Install pyyaml: pip install pyyaml")

ROOT = Path(__file__).resolve().parents[1]            # labs/
SRC = ROOT / "zava-power" / "sre-config"
DEST = ROOT / "recipes" / "azmon-aca-servicenow-zavapower-ops"

# Subset of agents that go in the ops recipe (everything except it-support-handler)
OPS_AGENTS = [
    "incident-handler",
    "deployment-validator",
    "vm-ops-agent",
    "utility-ops-agent",
    "web-app-troubleshooter",
    "pod-incident-remediator",
    "release-orchestrator",
    "pipeline-failure-investigator",
]

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", re.DOTALL)


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    print(f"  wrote {path.relative_to(ROOT)}")


def dump_yaml(data) -> str:
    return yaml.safe_dump(data, sort_keys=False, default_flow_style=False, width=120)


# --------------------------------------------------------------------- skills
def convert_skills() -> list[str]:
    skills_dir = SRC / "skills"
    names: list[str] = []
    for skill_dir in sorted(skills_dir.iterdir()):
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.exists():
            continue
        text = skill_md.read_text(encoding="utf-8-sig").replace("\r\n", "\n")
        m = FRONTMATTER_RE.match(text)
        if not m:
            print(f"  skip (no frontmatter): {skill_dir.name}")
            continue
        try:
            fm = yaml.safe_load(m.group(1)) or {}
        except yaml.YAMLError as e:
            print(f"  skip (yaml error in {skill_dir.name}): {e.__class__.__name__}")
            continue
        body = m.group(2).lstrip("\n")

        name = fm.get("name") or skill_dir.name
        # normalize name: lowercase, hyphens
        name = name.strip().lower().replace(" ", "-")
        description = (fm.get("description", "") or "").strip()
        # Tools may be at top level or under metadata.spec
        tools = fm.get("tools") or fm.get("metadata", {}).get("spec", {}).get("tools", []) or []

        names.append(name)

        # skill yaml
        skill_yaml = {
            "metadata": {
                "name": name,
                "description": description,
                "spec": {"tools": tools},
            },
            "skillContent": f"skills/{name}.md",
            "additionalFiles": [],
        }
        write(DEST / "config" / "skills" / f"{name}.yaml", dump_yaml(skill_yaml))
        write(DEST / "config" / "skills" / f"{name}.md", body)
    return names


# ----------------------------------------------------------------- subagents
def convert_subagents() -> list[str]:
    names: list[str] = []
    for agent_name in OPS_AGENTS:
        agent_yaml = SRC / "agents" / agent_name / f"{agent_name}.yaml"
        if not agent_yaml.exists():
            print(f"  WARN: {agent_yaml} not found")
            continue
        data = yaml.safe_load(agent_yaml.read_text(encoding="utf-8")) or {}
        spec = data.get("spec", {})

        # extract instructions to its own .md file
        instructions = spec.get("instructions", "").rstrip() + "\n"
        write(
            DEST / "config" / "subagents" / f"{agent_name}.instructions.md",
            instructions,
        )

        sub_yaml = {
            "metadata": {"name": agent_name},
            "spec": {
                "instructions": f"subagents/{agent_name}.instructions.md",
                "handoffDescription": spec.get("handoffDescription", "") or "",
                "tools": spec.get("tools", []) or [],
                "agentType": "Autonomous",
                "temperature": 0.2,
                "handoffs": spec.get("handoffs", []) or [],
                "enableSkills": bool(spec.get("enableSkills", False)),
                "allowedSkills": [],   # filled in after we know skill names
            },
        }
        names.append(agent_name)
        write(DEST / "config" / "subagents" / f"{agent_name}.yaml", dump_yaml(sub_yaml))
    return names


# ---------------------------------------------------------------- automations
def write_automations() -> list[str]:
    # ServiceNow incident-platform
    write(
        DEST / "automations" / "incident-platforms" / "servicenow.yaml",
        dump_yaml({"name": "servicenow", "spec": {"platformType": "ServiceNow"}}),
    )
    # AzureMonitor incident-platform
    write(
        DEST / "automations" / "incident-platforms" / "azure-monitor.yaml",
        dump_yaml({"name": "azure-monitor", "spec": {"platformType": "AzureMonitor"}}),
    )
    # Incident filter — auto-investigate (matches the lab response-plan)
    incident_filter = {
        "metadata": {"name": "auto-investigate-azmon"},
        "spec": {
            "incidentPlatform": "AzureMonitor",
            "isEnabled": True,
            "priorities": ["1", "2", "3"],
            "incidentType": "LiveSite",
            "handlingAgent": "incident-handler",
            "agentMode": "Autonomous",
            "deepInvestigationEnabled": False,
            "maxAutomatedInvestigationAttempts": 3,
            "azureMonitorFilterSettings": {
                "alertRules": [
                    "alert-powergrid-http-5xx",
                    "alert-powergrid-high-latency",
                    "alert-powergrid-container-restart",
                ],
                "triggerEvents": ["AlertFired"],
            },
        },
    }
    write(
        DEST / "automations" / "incident-filters" / "auto-investigate-azmon.yaml",
        dump_yaml(incident_filter),
    )

    # Scheduled task — pod fleet audit (daily)
    sched = {
        "metadata": {"name": "pod-fleet-audit-daily"},
        "spec": {
            "agent": "utility-ops-agent",
            "cronExpression": "0 8 * * *",
            "isEnabled": True,
            "agentPrompt": (
                "Run the pod-fleet-audit-deck skill end-to-end. "
                "Window: last 48 hours (UTC). Scope: all Container Apps in the target "
                "resource group. Output: ONE .pptx deck attached to this thread plus a "
                "one-paragraph executive summary. HARD CONSTRAINTS: do not create/modify "
                "ServiceNow incidents, do not run remediation, do not run incident-handler "
                "phases — only the deck workflow defined in the skill."
            ),
        },
    }
    write(
        DEST / "automations" / "scheduled-tasks" / "pod-fleet-audit-daily.yaml",
        dump_yaml(sched),
    )

    return ["auto-investigate-azmon"], ["pod-fleet-audit-daily"]


def main() -> None:
    print(f"Source:      {SRC}")
    print(f"Destination: {DEST}\n")
    if not SRC.exists():
        sys.exit(f"sre-config not found: {SRC}")

    print("== skills ==")
    skill_names = convert_skills()

    print("\n== subagents ==")
    subagent_names = convert_subagents()

    # backfill allowedSkills on every subagent — simplest policy: allow all
    for name in subagent_names:
        p = DEST / "config" / "subagents" / f"{name}.yaml"
        data = yaml.safe_load(p.read_text(encoding="utf-8"))
        data["spec"]["allowedSkills"] = sorted(skill_names)
        if skill_names:
            data["spec"]["enableSkills"] = True
        p.write_text(dump_yaml(data), encoding="utf-8")

    print("\n== automations ==")
    incident_filters, scheduled_tasks = write_automations()

    print(f"\nDone. {len(skill_names)} skills, {len(subagent_names)} subagents, "
          f"{len(incident_filters)} incident-filters, {len(scheduled_tasks)} scheduled-tasks.")


if __name__ == "__main__":
    main()
