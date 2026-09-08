#!/usr/bin/env python3
"""Verify every deployment and recipe allowlist matches supported-regions.json."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = json.loads((ROOT / "supported-regions.json").read_text())
ERRORS: list[str] = []


def check(name: str, actual: list[str]) -> None:
    if actual != EXPECTED:
        ERRORS.append(f"{name}: expected {EXPECTED}, found {actual}")


if EXPECTED != sorted(set(EXPECTED)) or len(EXPECTED) != 20:
    ERRORS.append("supported-regions.json must contain 20 unique, sorted regions")

bicep = (ROOT / "bicep/main.bicep").read_text()
bicep_match = re.search(r"@allowed\(\[([^]]+)]\)\s*\nparam location", bicep)
check("bicep/main.bicep", re.findall(r"'([^']+)'", bicep_match.group(1)) if bicep_match else [])

terraform = (ROOT / "terraform/variables.tf").read_text()
tf_match = re.search(r"contains\(\[([^]]+)], var\.location\)", terraform)
check("terraform/variables.tf", re.findall(r'"([^"]+)"', tf_match.group(1)) if tf_match else [])

clone = (ROOT / "bin/clone-agent.sh").read_text()
for variable in ("ALLOWED_REGIONS", "SUPPORTED_REGIONS"):
    match = re.search(rf'{variable}=\(([^)]+)\)', clone)
    check(f"bin/clone-agent.sh:{variable}", re.findall(r'"([^"]+)"', match.group(1)) if match else [])

starter_lab = (ROOT.parent / "labs/starter-lab/infra/main.bicep").read_text()
lab_match = re.search(r"@allowed\(\[([^]]+)]\)\s*\nparam location", starter_lab)
check("labs/starter-lab/infra/main.bicep", re.findall(r"'([^']+)'", lab_match.group(1)) if lab_match else [])

for recipe in sorted((ROOT / "recipes").glob("*/agent.json")):
    data = json.loads(recipe.read_text())
    location = data.get("_prompts", {}).get("location")
    if location and "options" in location:
        check(str(recipe.relative_to(ROOT)), location["options"])

docs = (ROOT / "docs/GETTING-STARTED.md").read_text().split("## Supported regions", 1)
if len(docs) != 2:
    ERRORS.append("docs/GETTING-STARTED.md: missing Supported regions section")
else:
    region_line = next((line for line in docs[1].splitlines() if line.strip()), "")
    listed = re.findall(r"`([a-z]+[0-9]*)`", region_line)
    check("docs/GETTING-STARTED.md", listed)

if ERRORS:
    for error in ERRORS:
        print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: all region allowlists match {len(EXPECTED)} canonical regions")
