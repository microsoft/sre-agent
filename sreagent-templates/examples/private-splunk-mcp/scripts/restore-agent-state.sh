#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 8 ]] || { echo "Usage: restore-agent-state.sh --subscription <id> --resource-group <rg> --agent-name <name> --state-file <file>" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --state-file) STATE_FILE="$2"; shift 2 ;;
    *) exit 1 ;;
  esac
done
[[ -f "$STATE_FILE" ]] || { echo "State file not found: $STATE_FILE" >&2; exit 1; }
AGENT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=2025-05-01-preview"
az rest --method PATCH --url "$AGENT_URL" --body "@$STATE_FILE" --output none
EXPECTED="$(jq -cS '.properties | {vnetConfiguration, sandboxConfiguration}' "$STATE_FILE")"
ACTUAL="$(az rest --method GET --url "$AGENT_URL" | jq -cS '.properties | {vnetConfiguration, sandboxConfiguration}')"
[[ "$EXPECTED" == "$ACTUAL" ]] || { echo "Restored writable fields do not match the captured state." >&2; exit 1; }
echo "Agent writable network and sandbox fields restored and verified."
