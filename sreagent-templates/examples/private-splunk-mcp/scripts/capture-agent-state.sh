#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 8 ]] || { echo "Usage: capture-agent-state.sh --subscription <id> --resource-group <rg> --agent-name <name> --output <file>" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) exit 1 ;;
  esac
done
AGENT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=2025-05-01-preview"
az rest --method GET --url "$AGENT_URL" | jq '{
  properties: {
    vnetConfiguration: .properties.vnetConfiguration,
    sandboxConfiguration: .properties.sandboxConfiguration
  }
}' >"$OUTPUT"
chmod 600 "$OUTPUT"
echo "Captured writable agent network and sandbox fields in $OUTPUT."
