#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${TEMPLATES_DIR}/.." && pwd)"
RECIPE_DIR="${REPO_DIR}/labs/onboardinglab/agent-recipe"
TMP_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then TMP_DIR="$(cygpath -m "$TMP_DIR")"; fi
trap 'rm -rf "$TMP_DIR"' EXIT

cp -R "$RECIPE_DIR" "$TMP_DIR/recipe"
mkdir -p "$TMP_DIR/recipe/config/connectorv2"
cp "$RECIPE_DIR/optional/connectorv2/outlook.yaml" "$TMP_DIR/recipe/config/connectorv2/"
bash "${TEMPLATES_DIR}/bicep/assemble-agent.sh" "$TMP_DIR/recipe" --output "$TMP_DIR/onboarding" >/dev/null
jq -e '
  (.connectorV2 | length) == 1 and
  .connectorV2[0].metadata.name == "outlook" and
  .connectorV2[0].spec.apiName == "office365" and
  .connectorV2[0].spec.connectionName == "office365"
' "$TMP_DIR/onboarding.extras.json" >/dev/null
jq '{connectorV2, knowledgeItems}' "$TMP_DIR/onboarding.extras.json" > "$TMP_DIR/connector.extras.json"

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
MOCK_BIN="$TMP_DIR/bin"
if command -v cygpath >/dev/null 2>&1; then MOCK_BIN="$(cygpath -u "$MOCK_BIN")"; fi

export CALL_LOG="$TMP_DIR/calls.log"
export MCP_BODY="$TMP_DIR/mcp-body.json"
PATH="$MOCK_BIN:$PATH" bash "${TEMPLATES_DIR}/bicep/apply-extras.sh" \
  test-subscription test-resource-group test-agent "$TMP_DIR/connector.extras.json" >/dev/null

cat > "$TMP_DIR/expected-calls.log" <<'EOF'
https://agent.test/api/v2/extendedAgent/connectors/onboardinglab-architecture-md
https://agent.test/api/v2/extendedAgent/connectors/onboardinglab-incident-r-2bcbfae
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

echo 'PASS: Bash deploys valid Knowledge Sources and the complete Outlook ConnectorV2 binding'