#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then TEMPLATES_DIR="$(cygpath -m "$TEMPLATES_DIR")"; fi
TMP_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then TMP_DIR="$(cygpath -m "$TMP_DIR")"; fi
trap 'rm -rf "$TMP_DIR"' EXIT

count=0
for config in "$TEMPLATES_DIR/agents/dg-azd-bash" "$TEMPLATES_DIR"/recipes/*; do
  [[ -d "$config/config/hooks" ]] || continue
  name=$(basename "$config")
  if ! bash "$TEMPLATES_DIR/bicep/assemble-agent.sh" "$config" --output "$TMP_DIR/$name" > "$TMP_DIR/assemble.log"; then
    cat "$TMP_DIR/assemble.log" >&2
    exit 1
  fi
  jq -e '
    (.hooks | length > 0) and
    all(.hooks[]; .properties.eventType == "PreToolUse" and
      .properties.hook.type == "command" and .properties.hook.failMode == "block" and
      .properties.hook.timeout == 10 and (.properties | has("permissionDecision") | not))
  ' "$TMP_DIR/$name.extras.json" >/dev/null
  jq -e '.parameters.enableDenyProdDeletesHook.value == false' "$TMP_DIR/$name.parameters.json" >/dev/null
  python3 - "$config" "$TMP_DIR/$name.extras.json" <<'PY'
import json
from pathlib import Path
import sys
import yaml

config = Path(sys.argv[1])
expected = {}
for path in (config / "config" / "hooks").glob("*.yaml"):
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    expected[document["metadata"]["name"]] = document["spec"]
extras = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
actual = {hook["name"]: hook["properties"] for hook in extras["hooks"]}
assert actual == expected, f"Hook content changed during assembly: {config.name}"
PY
  hooks=$(jq '.hooks | length' "$TMP_DIR/$name.extras.json")
  count=$((count + hooks))

  if command -v pwsh >/dev/null 2>&1; then
    if ! pwsh -NoLogo -NoProfile -File "$TEMPLATES_DIR/bicep/Assemble-Agent.ps1" \
      -ConfigDir "$config" -Output "$TMP_DIR/ps-$name" > "$TMP_DIR/ps-assemble.log"; then
      cat "$TMP_DIR/ps-assemble.log" >&2
      exit 1
    fi
    jq -S '[.hooks[] | {name,properties}] | sort_by(.name)' "$TMP_DIR/$name.extras.json" > "$TMP_DIR/bash-hooks.json"
    jq -S '[.hooks[] | {name,properties}] | sort_by(.name)' "$TMP_DIR/ps-$name.extras.json" > "$TMP_DIR/ps-hooks.json"
    diff -u "$TMP_DIR/bash-hooks.json" "$TMP_DIR/ps-hooks.json"
    jq -e '.parameters.enableDenyProdDeletesHook.value == false' "$TMP_DIR/ps-$name.parameters.json" >/dev/null
  fi
done
[[ "$count" -eq 12 ]]

mkdir "$TMP_DIR/legacy"
jq '.toggles.enableDenyProdDeletesHook = true' "$TEMPLATES_DIR/agents/dg-azd-bash/agent.json" > "$TMP_DIR/legacy/agent.json"
if ! bash "$TEMPLATES_DIR/bicep/assemble-agent.sh" "$TMP_DIR/legacy" \
  --output "$TMP_DIR/legacy-output" > "$TMP_DIR/legacy.log" 2>&1; then
  cat "$TMP_DIR/legacy.log" >&2
  exit 1
fi
grep -q 'added config hook deny-prod-deletes from defaults' "$TMP_DIR/legacy.log"
jq -e '.parameters.enableDenyProdDeletesHook.value == true' "$TMP_DIR/legacy-output.parameters.json" >/dev/null
python3 - "$TEMPLATES_DIR" "$TMP_DIR" <<'PY'
import json
from pathlib import Path
import sys
import yaml

templates, temporary = map(Path, sys.argv[1:])
default = yaml.safe_load((templates / "bicep/defaults/hooks/deny-prod-deletes.yaml").read_text(encoding="utf-8"))
hooks = json.loads((temporary / "legacy-output.extras.json").read_text(encoding="utf-8"))["hooks"]
assert len(hooks) == 1 and hooks[0]["name"] == "deny-prod-deletes"
assert hooks[0]["properties"] == default["spec"]
custom_dir = temporary / "custom"
(custom_dir / "config/hooks").mkdir(parents=True)
(custom_dir / "agent.json").write_text((temporary / "legacy/agent.json").read_text(encoding="utf-8"), encoding="utf-8")
default["spec"]["hook"]["timeout"] = 9
default["spec"]["hook"]["matcher"] = "CustomerSpecificWriteTool"
(custom_dir / "config/hooks/deny-prod-deletes.yaml").write_text(yaml.safe_dump(default), encoding="utf-8")
PY
bash "$TEMPLATES_DIR/bicep/assemble-agent.sh" "$TMP_DIR/custom" --output "$TMP_DIR/custom-output" > "$TMP_DIR/custom.log"
jq -e '.hooks | length == 1 and .[0].name == "deny-prod-deletes" and
  .[0].properties.hook.matcher == "CustomerSpecificWriteTool" and .[0].properties.hook.timeout == 9' \
  "$TMP_DIR/custom-output.extras.json" >/dev/null
if command -v pwsh >/dev/null 2>&1; then
  if ! pwsh -NoLogo -NoProfile -File "$TEMPLATES_DIR/bicep/Assemble-Agent.ps1" \
    -ConfigDir "$TMP_DIR/legacy" -Output "$TMP_DIR/ps-legacy-output" > "$TMP_DIR/ps-legacy.log" 2>&1; then
    cat "$TMP_DIR/ps-legacy.log" >&2
    exit 1
  fi
  grep -q 'added config hook deny-prod-deletes from defaults' "$TMP_DIR/ps-legacy.log"
  jq -e '.parameters.enableDenyProdDeletesHook.value == true' "$TMP_DIR/ps-legacy-output.parameters.json" >/dev/null
  pwsh -NoLogo -NoProfile -File "$TEMPLATES_DIR/bicep/Assemble-Agent.ps1" \
    -ConfigDir "$TMP_DIR/custom" -Output "$TMP_DIR/ps-custom-output" > "$TMP_DIR/ps-custom.log"
  for scenario in legacy custom; do
    jq -S '.hooks' "$TMP_DIR/$scenario-output.extras.json" > "$TMP_DIR/bash-hooks.json"
    jq -S '.hooks' "$TMP_DIR/ps-$scenario-output.extras.json" > "$TMP_DIR/ps-hooks.json"
    diff -u "$TMP_DIR/bash-hooks.json" "$TMP_DIR/ps-hooks.json"
  done
fi

echo 'PASS: All 12 command hooks survive assembly; legacy toggle adds one default and preserves customer hooks'
