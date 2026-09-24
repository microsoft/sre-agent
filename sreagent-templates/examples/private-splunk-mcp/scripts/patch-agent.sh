#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: patch-agent.sh --subscription <id> --resource-group <rg> --agent-name <name> --subnet-id <id> [--allow-subnet-reassignment]" >&2
}

SUBSCRIPTION="" RESOURCE_GROUP="" AGENT_NAME="" SUBNET_ID="" ALLOW_REASSIGNMENT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTION="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --subnet-id) SUBNET_ID="$2"; shift 2 ;;
    --allow-subnet-reassignment) ALLOW_REASSIGNMENT=true; shift ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
[[ -n "$SUBSCRIPTION" && -n "$RESOURCE_GROUP" && -n "$AGENT_NAME" && -n "$SUBNET_ID" ]] || { usage; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }

AGENT_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=2025-05-01-preview"
VNET_ID="${SUBNET_ID%/subnets/*}"
AGENT_JSON="$(az rest --method GET --url "$AGENT_URL")"
AGENT_LOCATION="$(jq -r '.location' <<<"$AGENT_JSON")"
CURRENT_SUBNET="$(jq -r '.properties.vnetConfiguration.subnetResourceId // ""' <<<"$AGENT_JSON")"
VNET_LOCATION="$(az rest --method GET --url "https://management.azure.com${VNET_ID}?api-version=2025-03-01" --query location --output tsv)"

if [[ "$(printf '%s' "$AGENT_LOCATION" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$VNET_LOCATION" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "Agent region '$AGENT_LOCATION' does not match agent VNet region '$VNET_LOCATION'." >&2
  exit 1
fi
if [[ -n "$CURRENT_SUBNET" && "${CURRENT_SUBNET,,}" != "${SUBNET_ID,,}" && "$ALLOW_REASSIGNMENT" != true ]]; then
  echo "The agent is already attached to a different subnet: $CURRENT_SUBNET" >&2
  echo "Pass --allow-subnet-reassignment only after capturing the original agent state." >&2
  exit 1
fi

BODY_FILE="$(mktemp "${TMPDIR:-.}/patch-sre-agent.XXXXXX.json")"
trap 'rm -f "$BODY_FILE"' EXIT
jq --arg subnetId "$SUBNET_ID" '{
  properties: {
    vnetConfiguration: ((.properties.vnetConfiguration // {}) + {subnetResourceId: $subnetId}),
    sandboxConfiguration: ((.properties.sandboxConfiguration // {}) + {
      egress: ((.properties.sandboxConfiguration.egress // {}) + {
        mode: "AzureVNet",
        allowHttpMcpServerNetworkAccess: false,
        vnetConfiguration: ((.properties.sandboxConfiguration.egress.vnetConfiguration // {}) + {usePrivateDnsResolution: true})
      })
    })
  }
}' <<<"$AGENT_JSON" >"$BODY_FILE"
az rest --method PATCH --url "$AGENT_URL" --body "@$BODY_FILE" --output none
echo "Agent VNet integration configured."
