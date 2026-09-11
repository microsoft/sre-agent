#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: patch-agent.sh --subscription <id> --resource-group <rg> --agent-name <name> --subnet-id <id>" >&2
}

SUBSCRIPTION=""
RESOURCE_GROUP=""
AGENT_NAME=""
SUBNET_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --subnet-id) SUBNET_ID="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$SUBSCRIPTION" && -n "$RESOURCE_GROUP" && -n "$AGENT_NAME" && -n "$SUBNET_ID" ]] || { usage; exit 1; }

AGENT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=2025-05-01-preview"
VNET_ID="${SUBNET_ID%/subnets/*}"
VNET_URL="https://management.azure.com${VNET_ID}?api-version=2025-03-01"

AGENT_JSON="$(az rest --method GET --url "$AGENT_URL")"
AGENT_LOCATION="$(jq -r '.location' <<<"$AGENT_JSON")"
CURRENT_SUBNET="$(jq -r '.properties.vnetConfiguration.subnetResourceId // ""' <<<"$AGENT_JSON")"
VNET_LOCATION="$(az rest --method GET --url "$VNET_URL" --query location --output tsv)"

NORMALIZED_AGENT_LOCATION="$(printf '%s' "$AGENT_LOCATION" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
NORMALIZED_VNET_LOCATION="$(printf '%s' "$VNET_LOCATION" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

if [[ "$NORMALIZED_AGENT_LOCATION" != "$NORMALIZED_VNET_LOCATION" ]]; then
  echo "Agent region '$AGENT_LOCATION' does not match agent VNet region '$VNET_LOCATION'." >&2
  exit 1
fi

CURRENT_SUBNET_LOWER="$(printf '%s' "$CURRENT_SUBNET" | tr '[:upper:]' '[:lower:]')"
SUBNET_ID_LOWER="$(printf '%s' "$SUBNET_ID" | tr '[:upper:]' '[:lower:]')"

if [[ -n "$CURRENT_SUBNET" && "$CURRENT_SUBNET_LOWER" != "$SUBNET_ID_LOWER" ]]; then
  echo "The agent is already attached to a different subnet: $CURRENT_SUBNET" >&2
  echo "This script will not reassign an existing VNet integration. Use a new agent or follow product guidance for migration." >&2
  exit 1
fi

az rest \
  --method PATCH \
  --url "$AGENT_URL" \
  --body "{\"properties\":{\"vnetConfiguration\":{\"subnetResourceId\":\"${SUBNET_ID}\"},\"sandboxConfiguration\":{\"egress\":{\"mode\":\"AzureVNet\",\"allowHttpMcpServerNetworkAccess\":false,\"vnetConfiguration\":{\"usePrivateDnsResolution\":true}}}}}" \
  --output none

echo "Agent VNet integration configured."
echo "Remote MCP infra-network bypass is disabled; private MCP traffic must use the customer VNet."
