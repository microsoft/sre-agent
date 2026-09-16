#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${TEMPLATES_DIR}/.." && pwd)"
RECIPE_DIR="${REPO_DIR}/labs/onboardinglab/agent-recipe"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

bash "${TEMPLATES_DIR}/bicep/assemble-agent.sh" "$RECIPE_DIR" --output "$TMP_DIR/onboarding" >/dev/null
jq -e '
  (.connectorV2 | length) == 1 and
  .connectorV2[0].metadata.name == "outlook" and
  .connectorV2[0].spec.apiName == "office365" and
  .connectorV2[0].spec.connectionName == "office365"
' "$TMP_DIR/onboarding.extras.json" >/dev/null
jq '{connectorV2}' "$TMP_DIR/onboarding.extras.json" > "$TMP_DIR/connector.extras.json"

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "rest" ]]; then
  printf '%s\n' '{"properties":{"agentEndpoint":"https://agent.test"},"identity":{"userAssignedIdentities":{}}}'
elif [[ "$1" == "account" && "$2" == "get-access-token" ]]; then
  printf '%s\n' 'test-token'
else
  printf 'Unexpected az call: %s\n' "$*" >&2
  exit 1
fi
EOF

cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=''
body=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    http*) url="$1" ;;
    --data|-d) shift; body="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$CALL_LOG"
if [[ "$url" == */mcpservers/office365 ]]; then
  printf '%s' "$body" > "$MCP_BODY"
fi
if [[ "$url" == */connections/office365 ]]; then
  printf '%s\n%s\n' '{"properties":{"overallStatus":"Connected"}}' '200'
else
  printf '%s\n%s\n' '{}' '200'
fi
EOF
chmod +x "$TMP_DIR/bin/az" "$TMP_DIR/bin/curl"

export CALL_LOG="$TMP_DIR/calls.log"
export MCP_BODY="$TMP_DIR/mcp-body.json"
PATH="$TMP_DIR/bin:$PATH" bash "${TEMPLATES_DIR}/bicep/apply-extras.sh" \
  test-subscription test-resource-group test-agent "$TMP_DIR/connector.extras.json" >/dev/null

cat > "$TMP_DIR/expected-calls.log" <<'EOF'
https://agent.test/api/v2/connectorV2/connections/office365
https://agent.test/api/v2/connectorV2/connections/office365/accessPolicies/office365-policy
https://agent.test/api/v2/connectorV2/mcpservers/office365
EOF
diff -u "$TMP_DIR/expected-calls.log" "$CALL_LOG"
jq -e '
  (.properties.connectors | length) == 1 and
  .properties.connectors[0].name == "office365" and
  .properties.connectors[0].connectionName == "office365"
' "$MCP_BODY" >/dev/null

echo 'PASS: Bash deploys the Outlook ConnectorV2 connection, access policy, and MCP binding'