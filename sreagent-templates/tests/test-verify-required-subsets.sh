#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${TEMPLATES_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/expected"

jq '.agent.defaultModelProvider = "Anthropic"' \
  "$REPO_DIR/labs/onboardinglab/agent-recipe/expected-config.json" \
  > "$TMP_DIR/expected/expected-config.json"

cat > "$TMP_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "account get-access-token" ]]; then
  printf '%s\n' 'test-token'
  exit 0
fi
if [[ "$1" == "rest" ]]; then
  url=''
  while [[ $# -gt 0 ]]; do
    [[ "$1" == '--url' ]] && { shift; url="$1"; }
    shift
  done
  if [[ "$url" == */DataConnectors* ]]; then
    printf '%s\n' '{"value":[{"name":"app-insights","properties":{"dataConnectorType":"AppInsights","provisioningState":"Succeeded"}},{"name":"onboardinglab-architecture-md","properties":{"dataConnectorType":"KnowledgeFile","provisioningState":"Succeeded"}}]}'
  else
    printf '%s\n' '{"properties":{"agentEndpoint":"https://agent.test","actionConfiguration":{"accessLevel":"Low","mode":"Review"},"upgradeChannel":"Preview","defaultModel":{"provider":"Anthropic"},"incidentManagementConfiguration":{"type":"AzMonitor"},"experimentalSettings":{}}}'
  fi
  exit 0
fi
printf 'Unexpected az call: %s\n' "$*" >&2
exit 1
EOF

cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=''
for arg in "$@"; do [[ "$arg" == http* ]] && url="$arg"; done
case "$url" in
  */api/v2/extendedAgent/connectors)
    printf '%s\n' '{"value":[{"name":"app-insights","properties":{"dataConnectorType":"AppInsights"}},{"name":"onboardinglab-architecture-md","properties":{"dataConnectorType":"KnowledgeFile"}},{"name":"onboardinglab-incident-r-2bcbfae","properties":{"dataConnectorType":"KnowledgeFile"}}]}' ;;
  */api/v2/connectorV2/mcpservers)
    printf '%s\n' '{"value":[{"name":"office365"}]}' ;;
  */api/v1/extendedAgent/skills)
    printf '%s\n' '[{"name":"sre-agent-self-configure"},{"name":"azure-monitor-rca"},{"name":"github-issue-followup"},{"name":"email-incident-followup"}]' ;;
  */api/v2/extendedAgent/agents)
    printf '%s\n' '{"value":[{"name":"alert-investigator"}]}' ;;
  */api/v2/extendedAgent/hooks)
    printf '%s\n' '{"value":[{"name":"evidence-checklist"}]}' ;;
  */api/v2/extendedAgent/commonprompts)
    printf '%s\n' '{"value":[{"name":"onboardinglab-safety"}]}' ;;
  */api/v2/extendedAgent/scheduledtasks)
    printf '%s\n' '{"value":[{"name":"proactive-health-check"}]}' ;;
  */api/v2/extendedAgent/incidentFilters)
    printf '%s\n' '{"value":[{"name":"alert-investigation"}]}' ;;
  */api/v2/github/domains)
    printf '%s\n' '{"values":[{"name":"github.com","authType":"OAuth","isHealthy":true}]}' ;;
  */api/v2/repos)
    printf '%s\n' '{"value":[{"name":"ticketingapp-source"}]}' ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$TMP_DIR/bin/az" "$TMP_DIR/bin/curl"

PATH="$TMP_DIR/bin:$PATH" bash "$TEMPLATES_DIR/bin/verify-agent.sh" \
  test-subscription test-resource-group test-agent --expected "$TMP_DIR/expected" \
  > "$TMP_DIR/bash-output.txt"
grep -q 'Results: .*0 failed' "$TMP_DIR/bash-output.txt"
grep -q 'Knowledge Sources.*2.*≥2.*PASS' "$TMP_DIR/bash-output.txt"
grep -q 'GitHub OAuth.*true' "$TMP_DIR/bash-output.txt"

if command -v pwsh >/dev/null 2>&1; then
  PATH="$TMP_DIR/bin:$PATH" pwsh -NoLogo -NoProfile -File "$TEMPLATES_DIR/bin/ps/Verify-Agent.ps1" \
    -Subscription test-subscription -ResourceGroup test-resource-group -AgentName test-agent \
    -Expected "$TMP_DIR/expected" > "$TMP_DIR/powershell-output.txt"
  grep -q 'Results: .*0 failed' "$TMP_DIR/powershell-output.txt"
  grep -q 'Knowledge Sources.*2.*≥2.*PASS' "$TMP_DIR/powershell-output.txt"
  grep -q 'GitHub OAuth.*true' "$TMP_DIR/powershell-output.txt"
fi

echo 'PASS: Bash and PowerShell verification allow workflow additions and require base resources'
