#!/usr/bin/env bash
# tests/test-assemble-config-integrity.sh
# assemble-agent.sh must never emit a silently empty or unresolved configuration.
# A missing PyYAML interpreter or an unreadable YAML file has to fail loudly,
# because an empty extras.json still deploys and strips an agent's configuration.
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLER="${TEMPLATES_DIR}/bicep/assemble-agent.sh"
TMP_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then TMP_DIR="$(cygpath -m "$TMP_DIR")"; fi
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

REAL_PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 \
    && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
    REAL_PYTHON="$(command -v "$candidate")"
    break
  fi
done
[[ -n "$REAL_PYTHON" ]] || fail 'test requires Python 3 with PyYAML'
export REAL_PYTHON

# ── Fixture: minimal recipe with one YAML skill whose content lives in a .md file ──
build_recipe() {
  local dir="$1"
  mkdir -p "$dir/config/skills" "$dir/config/connectorv2"
  cat > "$dir/agent.json" <<'EOF'
{
  "identity": { "agentName": "integrity-test", "resourceGroup": "rg-integrity", "location": "swedencentral" },
  "agent": { "accessLevel": "Low", "actionMode": "Review" }
}
EOF
  cat > "$dir/config/skills/sample.yaml" <<'EOF'
metadata:
  name: sample-skill
  description: Sample skill used by the integrity test.
  spec:
    tools: []
skillContent: skills/sample.md
additionalFiles: []
EOF
  printf '%s\n' '# Sample skill body' > "$dir/config/skills/sample.md"
  cat > "$dir/config/connectorv2/outlook.yaml" <<'EOF'
metadata:
  name: outlook
spec:
  apiName: office365
  connectionName: office365
EOF
}

# ── Case 1: healthy interpreter assembles YAML and inlines referenced content ──
build_recipe "$TMP_DIR/healthy"
bash "$ASSEMBLER" "$TMP_DIR/healthy" --output "$TMP_DIR/healthy-out" >/dev/null
jq -e '(.skills | length) == 1 and (.connectorV2 | length) == 1' \
  "$TMP_DIR/healthy-out.extras.json" >/dev/null \
  || fail 'healthy assembly dropped skills or connectorV2'
jq -e '.skills[0].skillContent | startswith("# Sample skill body")' \
  "$TMP_DIR/healthy-out.extras.json" >/dev/null \
  || fail 'healthy assembly left skillContent as an unresolved file reference'

# ── Case 2: Windows Python launcher must be invoked with its Python 3 selector ──
mkdir -p "$TMP_DIR/launcher-bin"
for stub in python3 python; do
  cat > "$TMP_DIR/launcher-bin/$stub" <<'EOF'
#!/usr/bin/env bash
exit 9009
EOF
  chmod +x "$TMP_DIR/launcher-bin/$stub"
done
cat > "$TMP_DIR/launcher-bin/py" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-3" ]] || exit 2
shift
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$TMP_DIR/launcher-bin/py"
LAUNCHER_BIN="$TMP_DIR/launcher-bin"
if command -v cygpath >/dev/null 2>&1; then LAUNCHER_BIN="$(cygpath -u "$LAUNCHER_BIN")"; fi

build_recipe "$TMP_DIR/launcher"
PATH="$LAUNCHER_BIN:$PATH" SRE_AGENT_PYTHON_HOME="$TMP_DIR/absent-python" \
  bash "$ASSEMBLER" "$TMP_DIR/launcher" --output "$TMP_DIR/launcher-out" >/dev/null
jq -e '(.skills | length) == 1 and (.connectorV2 | length) == 1' \
  "$TMP_DIR/launcher-out.extras.json" >/dev/null \
  || fail 'assembly did not use the Windows py -3 launcher'

# ── Case 3: no interpreter with PyYAML must fail instead of emitting empty config ──
# Reproduces the Windows App Execution Alias stub, which exits non-zero on import.
mkdir -p "$TMP_DIR/fakebin"
for stub in python3 python py; do
  cat > "$TMP_DIR/fakebin/$stub" <<'EOF'
#!/usr/bin/env bash
echo 'Python was not found; run without arguments to install from the Microsoft Store' >&2
exit 9009
EOF
  chmod +x "$TMP_DIR/fakebin/$stub"
done
FAKE_BIN="$TMP_DIR/fakebin"
if command -v cygpath >/dev/null 2>&1; then FAKE_BIN="$(cygpath -u "$FAKE_BIN")"; fi

build_recipe "$TMP_DIR/nopython"
set +e
PATH="$FAKE_BIN:$PATH" SRE_AGENT_PYTHON_HOME="$TMP_DIR/absent-python" \
  bash "$ASSEMBLER" "$TMP_DIR/nopython" --output "$TMP_DIR/nopython-out" \
  > "$TMP_DIR/nopython.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'assembly succeeded without a PyYAML interpreter'
grep -qi 'pyyaml' "$TMP_DIR/nopython.log" \
  || fail 'missing-interpreter error does not name the PyYAML requirement'
if [[ -f "$TMP_DIR/nopython-out.extras.json" ]] \
  && jq -e '(.skills | length) == 0' "$TMP_DIR/nopython-out.extras.json" >/dev/null 2>&1; then
  fail 'assembly wrote an empty extras file instead of failing'
fi

# ── Case 4: unparseable YAML must fail instead of being skipped ──
build_recipe "$TMP_DIR/badyaml"
printf '%s\n' 'metadata: [unclosed' > "$TMP_DIR/badyaml/config/skills/broken.yaml"
set +e
bash "$ASSEMBLER" "$TMP_DIR/badyaml" --output "$TMP_DIR/badyaml-out" \
  > "$TMP_DIR/badyaml.log" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || fail 'assembly succeeded despite an unparseable YAML file'
grep -q 'broken.yaml' "$TMP_DIR/badyaml.log" \
  || fail 'YAML parse failure does not name the offending file'

echo 'PASS: assemble-agent.sh fails loudly on a missing interpreter or unreadable YAML'
