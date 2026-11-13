#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PYTHON_BIN="$(command -v python3)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/azd" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "env get-value" ]]; then
  key="$3"
  case "$key" in
    SRE_AGENT_ENDPOINT) echo 'https://agent.test' ;;
    SRE_AGENT_NAME) echo 'starter-agent' ;;
    AZURE_RESOURCE_GROUP) echo 'rg-starter' ;;
    AZURE_ENV_NAME) echo "${TEST_ENVIRONMENT_NAME-starter-lab}" ;;
    CONTAINER_APP_URL) echo 'https://api.test' ;;
    CONTAINER_APP_NAME) echo 'api-app' ;;
    FRONTEND_APP_URL) echo 'https://web.test' ;;
    FRONTEND_APP_NAME) echo 'web-app' ;;
    AZURE_CONTAINER_REGISTRY_NAME) echo 'starteracr' ;;
    GITHUB_USER) echo "${TEST_GITHUB_USER:-}" ;;
  esac
  exit 0
fi
if [[ "$1 $2" == "env set" ]]; then exit 0; fi
echo "Unexpected azd call: $*" >&2
exit 1
EOF

cat > "$TMP_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "account get-access-token" ]]; then echo 'test-token'; exit 0; fi
if [[ "$1 $2" == "account show" ]]; then echo 'test-subscription'; exit 0; fi
if [[ "$1" == "rest" ]]; then
  if [[ "$*" == *"--method GET"* ]]; then echo 'AzMonitor'; fi
  exit 0
fi
echo "Unexpected az call: $*" >&2
exit 1
EOF

cat > "$TMP_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "$CALL_LOG"
exit 0
EOF

cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
method='GET'
url=''
output=''
write_code=false
data=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) shift; method="$1" ;;
    -o) shift; output="$1" ;;
    -w) shift; write_code=true ;;
    -d|--data-binary) shift; data="$1" ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$CALL_LOG"
if [[ "$data" == '@-' ]]; then
  printf '%s\t%s\n' "$url" "$(cat)" >> "${CALL_LOG}.payloads"
elif [[ -n "$data" ]]; then
  printf '%s\t%s\n' "$url" "$data" >> "${CALL_LOG}.payloads"
fi

response='{}'
http_code=200
curl_exit=0
case "$method $url" in
  'PUT https://agent.test/api/v2/extendedAgent/connectors/http-500-errors-md'|\
  'PUT https://agent.test/api/v2/extendedAgent/connectors/incident-report-template-md')
    attempt=$(grep -Fc "PUT $url" "$CALL_LOG")
    case "${TEST_UPLOAD_SCENARIO:-}" in
      transient)
        if [[ "$attempt" -eq 1 ]]; then http_code=405
        elif [[ "$attempt" -eq 2 ]]; then http_code=503; fi ;;
      exhausted) http_code=405 ;;
      forbidden) http_code=403 ;;
      transport)
        if [[ "$attempt" -eq 1 ]]; then http_code=000; curl_exit=7; fi ;;
    esac
    if [[ "$http_code" != 200 ]]; then response='{"error":"knowledge upload unavailable"}'; fi ;;
  'GET https://agent.test/api/v2/extendedAgent/connectors')
    if [[ "${TEST_MISSING_KNOWLEDGE:-false}" == true ]]; then
      response='{"value":[]}'
    else
      response='{"value":[{"name":"github-issue-triage-md","properties":{"dataConnectorType":"KnowledgeFile"}},{"name":"grubify-architecture-md","properties":{"dataConnectorType":"KnowledgeFile"}},{"name":"http-500-errors-md","properties":{"dataConnectorType":"KnowledgeFile"}},{"name":"incident-report-template-md","properties":{"dataConnectorType":"KnowledgeFile"}}]}'
    fi ;;
  'GET https://agent.test/api/v2/extendedAgent/agents')
    if [[ -n "${TEST_GITHUB_USER:-}" ]]; then
      response='{"value":[{"name":"incident-handler","properties":{"tools":[]}},{"name":"code-analyzer","properties":{"tools":[]}},{"name":"issue-triager","properties":{"tools":[]}}]}'
    else
      response='{"value":[{"name":"incident-handler","properties":{"tools":[]}}]}'
    fi ;;
  'GET https://agent.test/api/v2/github/domains')
    if [[ -n "${TEST_GITHUB_USER:-}" ]]; then response='{"values":[{"name":"github_com"}]}'; else response='{"values":[]}'; fi ;;
  'GET https://agent.test/api/v2/repos')
    if [[ -n "${TEST_GITHUB_USER:-}" ]]; then response='{"value":[{"name":"grubify"}]}'; else response='{"value":[]}'; fi ;;
  'GET https://agent.test/api/v2/extendedAgent/incidentFilters')
    response=$(python3 - "${CALL_LOG}.payloads" <<'PY'
import json
import os
from pathlib import Path
import sys

plans = [
    json.loads(body) for url, body in
    (line.split("\t", 1) for line in Path(sys.argv[1]).read_text().splitlines())
    if url.endswith("/incidentFilters/grubify-http-errors")
]
plan = plans[-1]
props = plan["properties"]
scenario = os.environ.get("TEST_RESPONSE_PLAN_SCENARIO", "")
if scenario == "legacy-title":
    props["titleContains"] = "alert-http-5xx-sre-lab"
elif scenario == "disabled":
    props["isEnabled"] = False
elif scenario == "wrong-agent":
    props["handlingAgent"] = "wrong-agent"
elif scenario == "wrong-platform":
    props["incidentPlatform"] = "PagerDuty"
elif scenario == "review-mode":
    props["agentMode"] = "Review"
elif scenario == "wrong-severity":
    props["priorities"] = ["Sev0"]
elif scenario == "extra-restriction":
    props["titleContainsAll"] = ["does-not-match"]
print(json.dumps({"value": [] if scenario == "missing" else [plan]}))
PY
) ;;
  'GET https://agent.test/api/v2/extendedAgent/scheduledtasks')
    if [[ -n "${TEST_GITHUB_USER:-}" ]]; then response='{"value":[{"name":"triage-grubify-issues","properties":{"cronExpression":"0 */12 * * *"}}]}'; else response='{"value":[]}'; fi ;;
esac

if [[ -n "$output" && "$output" != '/dev/null' ]]; then printf '%s' "$response" > "$output"; fi
if [[ -z "$output" ]]; then printf '%s' "$response"; fi
if [[ "$write_code" == true ]]; then printf '%s' "$http_code"; fi
exit "$curl_exit"
EOF

chmod +x "$TMP_DIR/bin/azd" "$TMP_DIR/bin/az" "$TMP_DIR/bin/curl" "$TMP_DIR/bin/sleep"
ln -s "$PYTHON_BIN" "$TMP_DIR/bin/python3"

run_scenario() {
  local github_user="$1"
  export TEST_GITHUB_USER="$github_user"
  export CALL_LOG="$TMP_DIR/calls-${github_user:-core}.log"
  : > "$CALL_LOG"
  : > "$CALL_LOG.payloads"
  PATH="$TMP_DIR/bin:/usr/bin:/bin" bash "$LAB_DIR/scripts/post-provision.sh" --retry > "$TMP_DIR/output-${github_user:-core}.txt"
  grep -q 'SRE Agent Lab Setup Complete' "$TMP_DIR/output-${github_user:-core}.txt"
  grep -q 'PUT https://agent.test/api/v2/extendedAgent/incidentFilters/grubify-http-errors' "$CALL_LOG"
  grep -q 'PUT https://agent.test/api/v2/extendedAgent/connectors/http-500-errors-md' "$CALL_LOG"
  "$PYTHON_BIN" - "$CALL_LOG.payloads" "${TEST_ENVIRONMENT_NAME-starter-lab}" <<'PY'
import json
from pathlib import Path
import sys

plans = [
    json.loads(body) for url, body in
    (line.split("\t", 1) for line in Path(sys.argv[1]).read_text().splitlines())
    if url.endswith("/incidentFilters/grubify-http-errors")
]
assert plans
for plan in plans:
    props = plan["properties"]
    assert props["titleContains"] == f"alert-http-5xx-{sys.argv[2]}"
    assert props["handlingAgent"] == "incident-handler"
    assert props["isEnabled"] is True
    assert props["agentMode"] == "Autonomous"
PY
}

run_scenario ''
run_scenario 'octocat'
grep -q 'PUT https://agent.test/api/v2/repos/grubify' "$TMP_DIR/calls-octocat.log"
grep -q 'PUT https://agent.test/api/v2/extendedAgent/scheduledtasks/triage-grubify-issues' "$TMP_DIR/calls-octocat.log"

for environment_name in sre-lab sre-ghprelaunch; do
  export TEST_ENVIRONMENT_NAME="$environment_name"
  run_scenario ''
done
unset TEST_ENVIRONMENT_NAME

export TEST_ENVIRONMENT_NAME=''
export CALL_LOG="$TMP_DIR/calls-no-environment.log"
if PATH="$TMP_DIR/bin:/usr/bin:/bin" bash "$LAB_DIR/scripts/post-provision.sh" --retry > "$TMP_DIR/output-no-environment.txt"; then
  echo 'Expected setup to fail without AZURE_ENV_NAME' >&2
  exit 1
fi
grep -q 'Could not read agent details or AZURE_ENV_NAME' "$TMP_DIR/output-no-environment.txt"
unset TEST_ENVIRONMENT_NAME

for scenario in legacy-title disabled wrong-agent wrong-platform review-mode wrong-severity extra-restriction missing; do
  export TEST_RESPONSE_PLAN_SCENARIO="$scenario"
  export CALL_LOG="$TMP_DIR/calls-plan-${scenario}.log"
  output="$TMP_DIR/output-plan-${scenario}.txt"
  if PATH="$TMP_DIR/bin:/usr/bin:/bin" bash "$LAB_DIR/scripts/post-provision.sh" --retry > "$output"; then
    echo "Expected verification to fail for response plan scenario: $scenario" >&2
    exit 1
  fi
  grep -q 'must be enabled and route alert-http-5xx-starter-lab to incident-handler autonomously' "$output"
  ! grep -q 'SRE Agent Lab Setup Complete' "$output"
done
unset TEST_RESPONSE_PLAN_SCENARIO

export TEST_GITHUB_USER=''
export TEST_MISSING_KNOWLEDGE=true
export CALL_LOG="$TMP_DIR/calls-missing.log"
if PATH="$TMP_DIR/bin:/usr/bin:/bin" bash "$LAB_DIR/scripts/post-provision.sh" --retry > "$TMP_DIR/output-missing.txt"; then
  echo 'Expected verification to fail when knowledge sources are missing' >&2
  exit 1
fi
grep -q 'Expected 4 knowledge sources, found 0' "$TMP_DIR/output-missing.txt"
unset TEST_MISSING_KNOWLEDGE

for scenario in transient exhausted forbidden transport; do
  export TEST_UPLOAD_SCENARIO="$scenario"
  export CALL_LOG="$TMP_DIR/calls-upload-${scenario}.log"
  output="$TMP_DIR/output-upload-${scenario}.txt"
  result=0
  PATH="$TMP_DIR/bin:/usr/bin:/bin" bash "$LAB_DIR/scripts/post-provision.sh" --retry > "$output" 2>&1 || result=$?
  case "$scenario" in
    transient) attempts=3; sleeps=4; expected_result=0 ;;
    exhausted) attempts=5; sleeps=8; expected_result=1 ;;
    forbidden) attempts=1; sleeps=0; expected_result=1 ;;
    transport) attempts=2; sleeps=2; expected_result=0 ;;
  esac
  [[ "$result" -eq "$expected_result" ]]
  for connector in http-500-errors-md incident-report-template-md; do
    [[ "$(grep -Fc "PUT https://agent.test/api/v2/extendedAgent/connectors/$connector" "$CALL_LOG")" -eq "$attempts" ]]
  done
  for connector in github-issue-triage-md grubify-architecture-md; do
    [[ "$(grep -Fc "PUT https://agent.test/api/v2/extendedAgent/connectors/$connector" "$CALL_LOG")" -eq 1 ]]
  done
  [[ "$(grep -c '^sleep 15$' "$CALL_LOG" || true)" -eq "$sleeps" ]]
  if [[ "$expected_result" -eq 0 ]]; then
    grep -q 'SRE Agent Lab Setup Complete' "$output"
  else
    grep -q 'API response: {"error":"knowledge upload unavailable"}' "$output"
    ! grep -q 'PUT https://agent.test/api/v2/extendedAgent/agents/' "$CALL_LOG"
    ! grep -q 'SRE Agent Lab Setup Complete' "$output"
  fi
  "$PYTHON_BIN" - "$CALL_LOG.payloads" "$LAB_DIR" <<'PY'
import base64
import json
from pathlib import Path
import sys

payloads = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    url, body = line.split("\t", 1)
    if "/connectors/" in url:
        payloads.setdefault(url, []).append(body)
for url, bodies in payloads.items():
    assert len(set(bodies)) == 1, f"Upload payload changed on retry: {url}"
    properties = json.loads(bodies[0])["properties"]["extendedProperties"]
    expected = (Path(sys.argv[2]) / "knowledge-base" / properties["fileName"]).read_bytes()
    assert base64.b64decode(properties["fileContent"]) == expected, url
PY
done
unset TEST_UPLOAD_SCENARIO

! grep -q 'api/v1/AgentMemory\|api/v1/incidentPlayground\|extendedAgent/connectors/github\|DataConnectors/github\|api/v1/github/config' "$LAB_DIR/scripts/post-provision.sh"
grep -q '^hooks:' "$LAB_DIR/azure.yaml"
grep -q 'postprovision:' "$LAB_DIR/azure.yaml"
! grep -q '^az login --use-device-code$\|^  azd auth login --use-device-code$' "$LAB_DIR/scripts/setup.sh"
grep -q 'az account show' "$LAB_DIR/scripts/setup.sh"

echo 'PASS: starter setup verifies environment-specific alert routing, core/GitHub scenarios and bounded knowledge upload retries'
