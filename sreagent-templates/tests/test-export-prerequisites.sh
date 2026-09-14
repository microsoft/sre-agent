#!/usr/bin/env bash
# Verify export-agent.sh fails clearly or installs PyYAML before contacting Azure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "Python 3.12.0"
  exit 0
fi
if [[ "${1:-}" == "-c" && "${2:-}" == *"import yaml"* ]]; then
  [[ -f "${FAKE_PYYAML_MARKER:?}" ]]
  exit $?
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" && "${3:-}" == "install" ]]; then
  if [[ -n "${FAKE_PIP_FAIL:-}" && "$0" != *"/python-home/bin/python" ]]; then
    exit 1
  fi
  touch "${FAKE_PYYAML_MARKER:?}"
  exit 0
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
  mkdir -p "$3/bin"
  ln -sf "$0" "$3/bin/python"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/python3"
ln -s python3 "$FAKE_BIN/python"

for cmd in az jq; do
  cat > "$FAKE_BIN/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
  chmod +x "$FAKE_BIN/$cmd"
done

run_export() {
  PATH="$FAKE_BIN:$PATH" \
  FAKE_PYYAML_MARKER="$TMP/pyyaml-installed" \
  FAKE_PIP_FAIL="${FAKE_PIP_FAIL:-}" \
  SRE_AGENT_PYTHON_HOME="$TMP/python-home" \
    "$ROOT/bin/export-agent.sh" \
      --subscription test-subscription \
      --resource-group test-resource-group \
      --agent-name test-agent \
      "$@" 2>&1
}

output=$(run_export --no-install-dependencies)
rc=$?
if [[ $rc -eq 0 || "$output" != *"Python 3 with PyYAML is required"* || "$output" != *"install-prerequisites.sh --python-only"* ]]; then
  echo "FAIL: missing-PyYAML opt-out path was not actionable" >&2
  echo "$output" >&2
  exit 1
fi

rm -f "$TMP/pyyaml-installed"
output=$(run_export)
rc=$?
if [[ ! -f "$TMP/pyyaml-installed" || "$output" != *"attempting to install it"* ]]; then
  echo "FAIL: exporter did not attempt automatic PyYAML installation" >&2
  echo "$output" >&2
  exit 1
fi
if [[ "$output" == *"Python 3 with PyYAML is required"* ]]; then
  echo "FAIL: exporter did not recognize PyYAML after installation" >&2
  echo "$output" >&2
  exit 1
fi

# The fake Azure CLI intentionally stops the export after prerequisite validation.
[[ $rc -ne 0 ]] || { echo "FAIL: fake Azure CLI should stop the export" >&2; exit 1; }

rm -rf "$TMP/python-home" "$TMP/pyyaml-installed"
output=$(FAKE_PIP_FAIL=1 run_export)
rc=$?
if [[ ! -x "$TMP/python-home/bin/python" || ! -f "$TMP/pyyaml-installed" ]]; then
  echo "FAIL: installer did not create an isolated environment after pip --user failed" >&2
  echo "$output" >&2
  exit 1
fi
if [[ "$output" != *"creating an isolated environment"* || "$output" == *"Python 3 with PyYAML is required"* ]]; then
  echo "FAIL: isolated-environment fallback was not recognized by the exporter" >&2
  echo "$output" >&2
  exit 1
fi
[[ $rc -ne 0 ]] || { echo "FAIL: fake Azure CLI should stop the export" >&2; exit 1; }

echo "PASS: exporter handles missing PyYAML before Azure export"
