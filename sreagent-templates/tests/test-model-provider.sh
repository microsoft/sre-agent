#!/usr/bin/env bash
set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${TEMPLATES_DIR}/.." && pwd)"
RECIPE_DIR="${REPO_DIR}/labs/onboardinglab/agent-recipe"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

common_args=(
  --recipe-path "$RECIPE_DIR"
  --subscription 00000000-0000-0000-0000-000000000000
  --set agentName=provider-test
  --set resourceGroup=rg-provider-test
  --set location=swedencentral
  --set appInsightsId=/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-provider-test/providers/Microsoft.Insights/components/app
  --set appInsightsAppId=00000000-0000-0000-0000-000000000001
  --set githubRepo=https://github.com/example/repo.git
  --non-interactive
  --no-telemetry
)

bash "$TEMPLATES_DIR/bin/new-agent.sh" "${common_args[@]}" --output "$TMP_DIR/default" >/dev/null
bash "$TEMPLATES_DIR/bin/new-agent.sh" "${common_args[@]}" --set modelProvider=Anthropic --output "$TMP_DIR/anthropic" >/dev/null
bash "$TEMPLATES_DIR/bin/new-agent.sh" "${common_args[@]}" --set "modelProvider=Azure OpenAI" --output "$TMP_DIR/foundry" >/dev/null

jq -e '.defaultModelProvider == "Anthropic"' "$TMP_DIR/default/agent.json" "$TMP_DIR/anthropic/agent.json" >/dev/null
jq -e '.defaultModelProvider == "MicrosoftFoundry"' "$TMP_DIR/foundry/agent.json" >/dev/null

jq '.defaultModelProvider = "Azure OpenAI"' "$TMP_DIR/default/agent.json" > "$TMP_DIR/default/agent.json.tmp"
mv "$TMP_DIR/default/agent.json.tmp" "$TMP_DIR/default/agent.json"
bash "$TEMPLATES_DIR/bicep/assemble-agent.sh" "$TMP_DIR/default" --output "$TMP_DIR/assembled" >/dev/null
jq -e '.parameters.defaultModelProvider.value == "MicrosoftFoundry"' "$TMP_DIR/assembled.parameters.json" >/dev/null
jq -e '.synthesizedKnowledgeDir == ""' "$TMP_DIR/assembled.extras.json" >/dev/null

echo 'PASS: Bash defaults to Anthropic and normalizes Azure OpenAI to MicrosoftFoundry'
