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
exit 0
EOF

cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
method='GET'
url=''
output=''
write_code=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) shift; method="$1" ;;
    -o) shift; output="$1" ;;
    -w) shift; write_code=true ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$CALL_LOG"

response='{}'
case "$method $url" in
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
    response='{"value":[{"name":"grubify-http-errors","properties":{"handlingAgent":"incident-handler"}}]}' ;;
  'GET https://agent.test/api/v2/extendedAgent/scheduledtasks')
    if [[ -n "${TEST_GITHUB_USER:-}" ]]; then response='{"value":[{"name":"triage-grubify-issues","properties":{"cronExpression":"0 */12 * * *"}}]}'; else response='{"value":[]}'; fi ;;
esac

if [[ -n "$output" && "$output" != '/dev/null' ]]; then printf '%s' "$response" > "$output"; fi
if [[ -z "$output" ]]; then printf '%s' "$response"; fi
if [[ "$write_code" == true ]]; then printf '200'; fi
EOF

chmod +x "$TMP_DIR/bin/azd" "$TMP_DIR/bin/az" "$TMP_DIR/bin/curl" "$TMP_DIR/bin/sleep"
ln -s "$PYTHON_BIN" "$TMP_DIR/bin/python3"

run_scenario() {
  local github_user="$1"
  export TEST_GITHUB_USER="$github_user"
  export CALL_LOG="$TMP_DIR/calls-${github_user:-core}.log"
  PATH="$TMP_DIR/bin:/usr/bin:/bin" bash "$LAB_DIR/scripts/post-provision.sh" --retry > "$TMP_DIR/output-${github_user:-core}.txt"
  grep -q 'SRE Agent Lab Setup Complete' "$TMP_DIR/output-${github_user:-core}.txt"
  grep -q 'PUT https://agent.test/api/v2/extendedAgent/incidentFilters/grubify-http-errors' "$CALL_LOG"
  grep -q 'PUT https://agent.test/api/v2/extendedAgent/connectors/http-500-errors-md' "$CALL_LOG"
}

run_scenario ''
run_scenario 'octocat'
grep -q 'PUT https://agent.test/api/v2/repos/grubify' "$TMP_DIR/calls-octocat.log"
grep -q 'PUT https://agent.test/api/v2/extendedAgent/scheduledtasks/triage-grubify-issues' "$TMP_DIR/calls-octocat.log"

export TEST_GITHUB_USER=''
export TEST_MISSING_KNOWLEDGE=true
export CALL_LOG="$TMP_DIR/calls-missing.log"
if PATH="$TMP_DIR/bin:/usr/bin:/bin" bash "$LAB_DIR/scripts/post-provision.sh" --retry > "$TMP_DIR/output-missing.txt"; then
  echo 'Expected verification to fail when knowledge sources are missing' >&2
  exit 1
fi
grep -q 'Expected 4 knowledge sources, found 0' "$TMP_DIR/output-missing.txt"
unset TEST_MISSING_KNOWLEDGE

! grep -q 'api/v1/AgentMemory\|api/v1/incidentPlayground\|extendedAgent/connectors/github\|DataConnectors/github\|api/v1/github/config' "$LAB_DIR/scripts/post-provision.sh"
grep -q '^hooks:' "$LAB_DIR/azure.yaml"
grep -q 'postprovision:' "$LAB_DIR/azure.yaml"
! grep -q '^az login --use-device-code$\|^  azd auth login --use-device-code$' "$LAB_DIR/scripts/setup.sh"
grep -q 'az account show' "$LAB_DIR/scripts/setup.sh"

echo 'PASS: starter setup configures and verifies core and GitHub scenarios through current APIs'
