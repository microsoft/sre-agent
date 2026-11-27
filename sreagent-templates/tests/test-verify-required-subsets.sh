#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${TEMPLATES_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then TMP_DIR="$(cygpath -m "$TMP_DIR")"; fi
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/expected"

jq '.agent.defaultModelProvider = "Anthropic"' \
  "$REPO_DIR/labs/onboardinglab/agent-recipe/expected-config.json" \
  > "$TMP_DIR/expected/expected-config.json"
export POLICY_FIXTURE="$TMP_DIR/expected/expected-config.json"
export HOOK_POLICY_MATCHER
HOOK_POLICY_MATCHER=$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["spec"]["hook"]["matcher"])' \
  "$TEMPLATES_DIR/agents/dg-azd-bash/config/hooks/require-approval-for-restarts.yaml")

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
    printf '%s\n' '[{"name":"sre-agent-self-configure"},{"name":"onboarding-lab-guide"},{"name":"onboarding-health-check"},{"name":"azure-monitor-rca"},{"name":"github-issue-followup"},{"name":"email-incident-followup"}]' ;;
  */api/v2/extendedAgent/skills/sre-agent-self-configure)
    printf '%s\n' '{"name":"sre-agent-self-configure","properties":{"description":"Configure this agent.","tools":["GetAzCliHelp","RunAzCliReadCommands","RunAzCliWriteCommands"],"skillContent":"# Configure"}}' ;;
  */api/v2/extendedAgent/skills/onboarding-lab-guide)
    printf '%s\n' '{"name":"onboarding-lab-guide","properties":{"description":"Guide the lab.","tools":[],"skillContent":"# Guide"}}' ;;
  */api/v2/extendedAgent/skills/onboarding-health-check)
    printf '%s\n' '{"name":"onboarding-health-check","properties":{"description":"Read-only health check.","tools":["QueryAppInsightsUsingAppId"],"skillContent":"# Health"}}' ;;
  */api/v2/agent/settings/global)
    jq '{permissions:.toolPermissions}' "$POLICY_FIXTURE" ;;
  */api/v2/extendedAgent/agents)
    printf '%s\n' '{"value":[{"name":"alert-investigator"}]}' ;;
  */api/v2/extendedAgent/hooks)
    if [[ "${HOOK_TEST_MODE:-}" == "hooks-error" ]]; then exit 22; fi
    jq -cn --arg matcher "${HOOK_TEST_MATCHER-$HOOK_POLICY_MATCHER}" \
      '{value:[{name:"evidence-checklist",properties:{eventType:"Stop"}},{name:"cli-review",properties:{eventType:"PreToolUse",hook:{matcher:$matcher}}}]}' ;;
  */api/v2/agent/tools)
    case "${HOOK_TEST_MODE:-}" in
      http-error) exit 22 ;;
      invalid-json) printf '%s\n' '<html>Sign in</html>' ;;
      invalid-shape) printf '%s\n' '{}' ;;
      empty) printf '%s\n' '{"data":[]}' ;;
      disabled) printf '%s\n' '{"data":[{"name":"RunAzCliWriteCommands","enabled":false}]}' ;;
      builtin) printf '%s\n' '{"data":[{"name":"RestartWebApp","enabled":true}]}' ;;
      *) printf '%s\n' '{"data":[{"name":"RunAzCliWriteCommands","enabled":true},{"name":"RunKubectlWriteCommand","enabled":true},{"name":"aws-mcp_ec2_terminate-instances","enabled":true}]}' ;;
    esac ;;
  */api/v2/extendedAgent/commonprompts)
    printf '%s\n' '{"value":[{"name":"onboardinglab-safety"}]}' ;;
  */api/v2/extendedAgent/scheduledtasks)
    printf '%s\n' '{"value":[{"name":"proactive-health-check"}]}' ;;
  */api/v2/extendedAgent/incidentFilters)
    printf '%s\n' '{"value":[{"name":"alert-investigation"}]}' ;;
  */api/v2/github/domains)
    printf '%s\n' '{"values":[{"name":"github.com","authType":"OAuth","isHealthy":true}]}' ;;
  */api/v2/repos)
    printf '%s\n' '{"value":[{"name":"ticketingapp-source","properties":{"branch":"main"}}]}' ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$TMP_DIR/bin/az" "$TMP_DIR/bin/curl"
MOCK_BIN="$TMP_DIR/bin"
if command -v cygpath >/dev/null 2>&1; then MOCK_BIN="$(cygpath -u "$MOCK_BIN")"; fi

if ! PATH="$MOCK_BIN:$PATH" bash "$TEMPLATES_DIR/bin/verify-agent.sh" \
  test-subscription test-resource-group test-agent --expected "$TMP_DIR/expected" \
  > "$TMP_DIR/bash-output.txt"; then
  cat "$TMP_DIR/bash-output.txt" >&2
  exit 1
fi
grep -q 'Results: .*0 failed' "$TMP_DIR/bash-output.txt"
grep -q 'Knowledge Sources.*2.*≥2.*PASS' "$TMP_DIR/bash-output.txt"
grep -q 'GitHub OAuth.*true' "$TMP_DIR/bash-output.txt"
grep -q 'Hook matcher (cli-review).*PASS' "$TMP_DIR/bash-output.txt"
if ! HOOK_TEST_MODE=builtin PATH="$MOCK_BIN:$PATH" bash "$TEMPLATES_DIR/bin/verify-agent.sh" \
  test-subscription test-resource-group test-agent --expected "$TMP_DIR/expected" \
  > "$TMP_DIR/bash-builtin.txt"; then
  cat "$TMP_DIR/bash-builtin.txt" >&2
  exit 1
fi
grep -q 'Hook matcher (cli-review).*PASS' "$TMP_DIR/bash-builtin.txt"

for matcher in '^(restart_|scale_).*' 'runazcliwritecommands' 'RunAzCliWrite' '' '['; do
  if HOOK_TEST_MATCHER="$matcher" PATH="$MOCK_BIN:$PATH" bash "$TEMPLATES_DIR/bin/verify-agent.sh" \
    test-subscription test-resource-group test-agent --expected "$TMP_DIR/expected" \
    > "$TMP_DIR/bash-invalid.txt" 2>&1; then
    echo "FAIL: Bash verification accepted matcher '$matcher'" >&2
    exit 1
  fi
  grep -q 'Hook matcher (cli-review).*FAIL' "$TMP_DIR/bash-invalid.txt" || { cat "$TMP_DIR/bash-invalid.txt" >&2; exit 1; }
done
for mode in http-error invalid-json invalid-shape empty disabled hooks-error; do
  if HOOK_TEST_MODE="$mode" PATH="$MOCK_BIN:$PATH" bash "$TEMPLATES_DIR/bin/verify-agent.sh" \
    test-subscription test-resource-group test-agent --expected "$TMP_DIR/expected" \
    > "$TMP_DIR/bash-unavailable.txt" 2>&1; then
    echo "FAIL: Bash verification accepted unavailable hooks/tools ($mode)" >&2
    exit 1
  fi
  grep -q 'FAIL' "$TMP_DIR/bash-unavailable.txt" || { cat "$TMP_DIR/bash-unavailable.txt" >&2; exit 1; }
done

if command -v pwsh >/dev/null 2>&1; then
  cat > "$TMP_DIR/verify-harness.ps1" <<'EOF'
param($MockDirectory, $Verifier, $Expected)
$ErrorActionPreference = 'Stop'
function az { & bash (Join-Path $MockDirectory 'az') @args }
function Invoke-WebRequest {
  param($Uri, $Headers, $TimeoutSec, [switch]$SkipHttpErrorCheck)
  $body = (& bash (Join-Path $MockDirectory 'curl') $Uri) -join "`n"
  if ($LASTEXITCODE -ne 0) { throw 'Mock transport failed.' }
  [pscustomobject]@{ StatusCode = 200; Content = $body }
}
& $Verifier -Subscription test-subscription -ResourceGroup test-resource-group -AgentName test-agent -Expected $Expected
exit $LASTEXITCODE
EOF
  pwsh -NoLogo -NoProfile -File "$TMP_DIR/verify-harness.ps1" \
    -MockDirectory "$TMP_DIR/bin" -Verifier "$TEMPLATES_DIR/bin/ps/Verify-Agent.ps1" \
    -Expected "$TMP_DIR/expected" > "$TMP_DIR/powershell-output.txt"
  grep -q 'Results: .*0 failed' "$TMP_DIR/powershell-output.txt"
  grep -q 'Knowledge Sources.*2.*≥2.*PASS' "$TMP_DIR/powershell-output.txt"
  grep -q 'GitHub OAuth.*true' "$TMP_DIR/powershell-output.txt"
  grep -q 'Hook matcher (cli-review).*PASS' "$TMP_DIR/powershell-output.txt"
  if ! HOOK_TEST_MODE=builtin pwsh -NoLogo -NoProfile -File "$TMP_DIR/verify-harness.ps1" \
    -MockDirectory "$TMP_DIR/bin" -Verifier "$TEMPLATES_DIR/bin/ps/Verify-Agent.ps1" \
    -Expected "$TMP_DIR/expected" > "$TMP_DIR/powershell-builtin.txt"; then
    cat "$TMP_DIR/powershell-builtin.txt" >&2
    exit 1
  fi
  grep -q 'Hook matcher (cli-review).*PASS' "$TMP_DIR/powershell-builtin.txt"
  for matcher in '^(restart_|scale_).*' 'runazcliwritecommands' 'RunAzCliWrite' '' '['; do
    if HOOK_TEST_MATCHER="$matcher" pwsh -NoLogo -NoProfile -File "$TMP_DIR/verify-harness.ps1" \
      -MockDirectory "$TMP_DIR/bin" -Verifier "$TEMPLATES_DIR/bin/ps/Verify-Agent.ps1" \
      -Expected "$TMP_DIR/expected" > "$TMP_DIR/powershell-invalid.txt" 2>&1; then
      echo "FAIL: PowerShell verification accepted matcher '$matcher'" >&2
      exit 1
    fi
    grep -q 'Hook matcher (cli-review).*FAIL' "$TMP_DIR/powershell-invalid.txt" || { cat "$TMP_DIR/powershell-invalid.txt" >&2; exit 1; }
  done
  for mode in http-error invalid-json invalid-shape empty disabled hooks-error; do
    if HOOK_TEST_MODE="$mode" pwsh -NoLogo -NoProfile -File "$TMP_DIR/verify-harness.ps1" \
      -MockDirectory "$TMP_DIR/bin" -Verifier "$TEMPLATES_DIR/bin/ps/Verify-Agent.ps1" \
      -Expected "$TMP_DIR/expected" > "$TMP_DIR/powershell-unavailable.txt" 2>&1; then
      echo "FAIL: PowerShell verification accepted unavailable hooks/tools ($mode)" >&2
      exit 1
    fi
    grep -q 'FAIL' "$TMP_DIR/powershell-unavailable.txt" || { cat "$TMP_DIR/powershell-unavailable.txt" >&2; exit 1; }
  done
fi

grep -q '"strictVerification": true' "$REPO_DIR/labs/onboardinglab/agent-recipe/expected-config.json"
grep -q 'STRICT_VERIFICATION' "$TEMPLATES_DIR/bin/deploy.sh"
grep -q '\$StrictVerification' "$TEMPLATES_DIR/bin/ps/Deploy-Agent.ps1"

echo 'PASS: Bash and PowerShell verification allow workflow additions and require base resources'
echo 'PASS: Hook matchers require enabled tools; invalid matchers and unavailable inventories fail verification'
