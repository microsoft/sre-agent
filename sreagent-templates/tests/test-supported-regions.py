#!/usr/bin/env python3
"""Verify region discovery has one checked-in fallback and no deployment allowlists."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = json.loads((ROOT / "supported-regions.json").read_text())
ERRORS: list[str] = []


if EXPECTED != sorted(set(EXPECTED)) or len(EXPECTED) != 20:
    ERRORS.append("supported-regions.json must contain 20 unique, sorted regions")

bicep = (ROOT / "bicep/main.bicep").read_text()
if re.search(r"@allowed\(\[[^]]+\]\)\s*\nparam location", bicep):
    ERRORS.append("bicep/main.bicep: location must not use a static allowlist")

terraform = (ROOT / "terraform/variables.tf").read_text()
if re.search(r"contains\(\[[^]]+], var\.location\)", terraform):
    ERRORS.append("terraform/variables.tf: location must not use a static allowlist")

clone = (ROOT / "bin/clone-agent.sh").read_text()
if "ALLOWED_REGIONS=" in clone or "SUPPORTED_REGIONS=" in clone:
    ERRORS.append("bin/clone-agent.sh: region validation must use subscription discovery")

starter_lab = (ROOT.parent / "labs/starter-lab/infra/main.bicep").read_text()
if re.search(r"@allowed\(\[[^]]+\]\)\s*\nparam location", starter_lab):
    ERRORS.append("labs/starter-lab/infra/main.bicep: location must not use a static allowlist")

for recipe in sorted((ROOT / "recipes").glob("*/agent.json")):
    data = json.loads(recipe.read_text())
    location = data.get("_prompts", {}).get("location")
    if location and "options" in location:
        ERRORS.append(f"{recipe.relative_to(ROOT)}: location options must come from subscription discovery")

for helper in (ROOT / "bin/region-utils.sh", ROOT / "bin/ps/Region-Utils.ps1"):
    content = helper.read_text()
    if "Microsoft.App" not in content or "supported-regions.json" not in content:
        ERRORS.append(f"{helper.relative_to(ROOT)}: missing live discovery or checked-in fallback")

docs = (ROOT / "docs/GETTING-STARTED.md").read_text().split("## Supported regions", 1)
if len(docs) != 2:
    ERRORS.append("docs/GETTING-STARTED.md: missing Supported regions section")
else:
    region_line = next((line for line in docs[1].splitlines() if line.strip()), "")
    listed = re.findall(r"`([a-z]+[0-9]*)`", region_line)
    if listed != EXPECTED:
        ERRORS.append(f"docs/GETTING-STARTED.md: expected {EXPECTED}, found {listed}")

if ERRORS:
    for error in ERRORS:
        print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: region discovery uses one {len(EXPECTED)}-region offline fallback")
