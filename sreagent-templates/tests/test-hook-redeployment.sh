#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then TEMPLATES_DIR="$(cygpath -m "$TEMPLATES_DIR")"; fi
TMP_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then TMP_DIR="$(cygpath -m "$TMP_DIR")"; fi
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/config/config/hooks" "$TMP_DIR/config/config/skills"
printf '%s\n' 'metadata:' '  name: unrelated-skill' > "$TMP_DIR/config/config/skills/unrelated-skill.yaml"
cat > "$TMP_DIR/config/agent.json" <<'JSON'
{"identity":{"agentName":"test-agent","resourceGroup":"test-rg","subscription":"test-sub","location":"swedencentral","targetResourceGroups":[]},"access":{"accessLevel":"Low","actionMode":"Review"},"toggles":{"enableDenyProdDeletesHook":true}}
JSON
printf '%s\n' '{"toggles":{},"connectors":[]}' > "$TMP_DIR/config/connectors.json"

cat > "$TMP_DIR/bin/az" <<'BASH'
#!/usr/bin/env bash
if [[ "$1 $2" == 'account get-access-token' ]]; then
  printf '%s\n' 'mock-token'
elif [[ "$*" == *DataConnectors* ]]; then
  printf '\n'
else
  printf '%s\n' '{"properties":{"agentEndpoint":"https://agent.test"}}'
fi
BASH
cat > "$TMP_DIR/bin/curl" <<'BASH'
#!/usr/bin/env bash
url=''
for arg in "$@"; do [[ "$arg" == https:* ]] && url="$arg"; done
case "$url" in
  */hooks) cat "$HOOK_DIFF_FIXTURE"; exit "${HOOK_DIFF_HTTP_EXIT:-0}" ;;
  */skills) printf '%s\n' '[{"name":"unrelated-skill"}]' ;;
  */scheduledtasks|*/incidentPlayground/filters|*/incidentPlayground/handlers) printf '%s\n' '[]' ;;
  *) printf '%s\n' '{"value":[]}' ;;
esac
BASH
chmod +x "$TMP_DIR/bin/az" "$TMP_DIR/bin/curl"
MOCK_BIN="$TMP_DIR/bin"
if command -v cygpath >/dev/null 2>&1; then MOCK_BIN="$(cygpath -u "$MOCK_BIN")"; fi

cat > "$TMP_DIR/harness.ps1" <<'PS'
param($MockDirectory, $Verifier, $ConfigDirectory, $Extras)
$ErrorActionPreference = 'Stop'
function az { & bash (Join-Path $MockDirectory 'az') @args }
function curl { & bash (Join-Path $MockDirectory 'curl') @args }
function Invoke-WebRequest {
    param($Uri, $Headers, $TimeoutSec, [switch]$SkipHttpErrorCheck)
    $body = (& bash (Join-Path $MockDirectory 'curl') $Uri) -join "`n"
    [pscustomobject]@{ StatusCode = $(if ($LASTEXITCODE) { 500 } else { 200 }); Content = $body }
}
$parameters = @{
    Subscription = 'test-sub'; ResourceGroup = 'test-rg'; AgentName = 'test-agent'; ConfigDir = $ConfigDirectory
}
if ($Extras) { $parameters.ExtrasFile = $Extras }
& $Verifier @parameters
exit $LASTEXITCODE
PS

export HOOK_DIFF_FIXTURE="$TMP_DIR/deployed.json"
for scenario in missing matcher script type failMode timeout identical normalized orphan malformed unavailable; do
  python3 - "$TEMPLATES_DIR" "$TMP_DIR" "$scenario" <<'PY'
import json
from pathlib import Path
import sys
import yaml

templates, temporary = map(Path, sys.argv[1:3])
scenario = sys.argv[3]
definition = yaml.safe_load((templates / "bicep/defaults/hooks/deny-prod-deletes.yaml").read_text(encoding="utf-8"))
hook = {"name": definition["metadata"]["name"], "properties": definition["spec"]}
deployed = json.loads(json.dumps(hook))
if scenario == "matcher": deployed["properties"]["hook"]["matcher"] = "delete_.*"
if scenario == "script": deployed["properties"]["hook"]["script"] += "\nprint('changed')\n"
if scenario == "type": deployed["properties"]["hook"]["type"] = "prompt"
if scenario == "failMode": deployed["properties"]["hook"]["failMode"] = "allow"
if scenario == "timeout": deployed["properties"]["hook"]["timeout"] = 20
if scenario == "normalized":
    deployed["properties"]["hook"]["script"] = deployed["properties"]["hook"]["script"].replace("\n", "\r\n") + "\r\n"
    deployed["properties"]["hook"]["type"] = "Command"
    deployed["properties"]["hook"]["prompt"] = None
    deployed["properties"]["activationMode"] = "always"
    deployed["metadata"] = {"updatedAt": "ignored"}
rows = [] if scenario == "missing" else [deployed]
if scenario == "orphan":
    rows.append(dict(deployed, name="other-hook"))
payload = {"value": rows} if scenario != "malformed" else {"error": "unavailable"}
(temporary / "deployed.json").write_text(json.dumps(payload), encoding="utf-8")
(temporary / "expected.extras.json").write_text(json.dumps({"hooks": [hook]}), encoding="utf-8")
PY
  expected=1 action='~ UPDATE'
  case "$scenario" in
    missing) action='+ CREATE' ;;
    identical|normalized|orphan) expected=0 action='= match' ;;
    malformed|unavailable) expected=3 action='Hook comparison' ;;
  esac
  export HOOK_DIFF_HTTP_EXIT=0
  [[ "$scenario" != unavailable ]] || export HOOK_DIFF_HTTP_EXIT=22
  # Exercise standalone assembly for the missing default and same-name update.
  extras_args=()
  [[ "$scenario" == missing || "$scenario" == matcher ]] || extras_args=(--extras "$TMP_DIR/expected.extras.json")
  if [[ "$scenario" == matcher ]]; then
    cp "$TEMPLATES_DIR/bicep/defaults/hooks/deny-prod-deletes.yaml" "$TMP_DIR/config/config/hooks/deny-prod-deletes.yaml"
  fi
  rc=0
  PATH="$MOCK_BIN:$PATH" bash "$TEMPLATES_DIR/bin/diff-agent.sh" \
    test-sub test-rg test-agent "$TMP_DIR/config" "${extras_args[@]}" > "$TMP_DIR/bash-result.txt" 2>&1 || rc=$?
  if [[ "$rc" != "$expected" ]] || ! grep -Fq "$action" "$TMP_DIR/bash-result.txt"; then
    cat "$TMP_DIR/bash-result.txt" >&2
    echo "FAIL: Bash $scenario exit=$rc expected=$expected" >&2
    exit 1
  fi
  if [[ "$expected" != 3 ]]; then
    grep -Fq 'skills/unrelated-skill' "$TMP_DIR/bash-result.txt"
  fi
  if command -v pwsh >/dev/null 2>&1; then
    extras_args=()
    [[ "$scenario" == missing || "$scenario" == matcher ]] || extras_args=(-Extras "$TMP_DIR/expected.extras.json")
    rc=0
    pwsh -NoLogo -NoProfile -File "$TMP_DIR/harness.ps1" \
      -MockDirectory "$TMP_DIR/bin" -Verifier "$TEMPLATES_DIR/bin/ps/Diff-Agent.ps1" \
      -ConfigDirectory "$TMP_DIR/config" "${extras_args[@]}" > "$TMP_DIR/ps-result.txt" 2>&1 || rc=$?
    if [[ "$rc" != "$expected" ]] || ! grep -Fq "$action" "$TMP_DIR/ps-result.txt"; then
      cat "$TMP_DIR/ps-result.txt" >&2
      echo "FAIL: PowerShell $scenario exit=$rc expected=$expected" >&2
      exit 1
    fi
    if [[ "$expected" != 3 ]]; then
      grep -Fq 'skills/unrelated-skill' "$TMP_DIR/ps-result.txt"
    fi
  fi
done
echo 'PASS: hook redeployment detects assembler defaults and definition updates; identical hooks skip; failed comparisons do not report no change'
