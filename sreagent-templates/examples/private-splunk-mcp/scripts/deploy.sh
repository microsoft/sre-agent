#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: deploy.sh bicep --resource-group <name> --parameters <file> | deploy.sh terraform --tfvars <file>" >&2
}

BACKEND="${1:-}"
[[ -n "$BACKEND" ]] || { usage; exit 1; }
shift
RESOURCE_GROUP=""
PARAMETERS=""
TFVARS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --parameters) PARAMETERS="$2"; shift 2 ;;
    --tfvars) TFVARS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=validation.sh
source "$SCRIPT_DIR/validation.sh"

read_tfvar() {
  local name="$1" file="$2" fallback="${3:-}"
  local value
  value="$(sed -nE "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | tail -n 1)"
  printf '%s' "${value:-$fallback}"
}

case "$BACKEND" in
  bicep)
    [[ -n "$RESOURCE_GROUP" && -f "$PARAMETERS" ]] || { usage; exit 1; }
    command -v az >/dev/null || { echo "Azure CLI is required." >&2; exit 1; }
    command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
    TOPOLOGY="$(jq -r '.parameters.topology.value // ""' "$PARAMETERS")"
    AGENT_LOCATION="$(jq -r '.parameters.agentLocation.value // "eastus2"' "$PARAMETERS")"
    SPLUNK_LOCATION="$(jq -r '.parameters.splunkLocation.value // empty' "$PARAMETERS")"
    SPLUNK_LOCATION="${SPLUNK_LOCATION:-$AGENT_LOCATION}"
    AGENT_VNET="$(jq -r '.parameters.agentVnetAddressPrefix.value // "10.100.0.0/16"' "$PARAMETERS")"
    SPLUNK_VNET="$(jq -r '.parameters.splunkVnetAddressPrefix.value // empty' "$PARAMETERS")"
    SPLUNK_VNET="${SPLUNK_VNET:-$AGENT_VNET}"
    AGENT_SUBNET="$(jq -r '.parameters.agentSubnetPrefix.value // "10.100.0.0/27"' "$PARAMETERS")"
    SPLUNK_SUBNET="$(jq -r '.parameters.splunkSubnetPrefix.value // "10.100.1.0/24"' "$PARAMETERS")"
    PRIVATE_IP="$(jq -r '.parameters.splunkPrivateIp.value // "10.100.1.4"' "$PARAMETERS")"
    SSH_KEY="$(jq -r '.parameters.adminSshPublicKey.value // ""' "$PARAMETERS")"
    validate_deployment_inputs "$TOPOLOGY" "$AGENT_LOCATION" "$SPLUNK_LOCATION" "$AGENT_VNET" "$SPLUNK_VNET" "$AGENT_SUBNET" "$SPLUNK_SUBNET" "$PRIVATE_IP" "$SSH_KEY"
    az group create --name "$RESOURCE_GROUP" --location "$AGENT_LOCATION" --output none
    az deployment group create --resource-group "$RESOURCE_GROUP" --name "private-splunk-${TOPOLOGY}-$(date +%Y%m%d-%H%M%S)" --template-file "$EXAMPLE_DIR/bicep/main.bicep" --parameters "@$PARAMETERS" --output json
    ;;
  terraform)
    [[ -f "$TFVARS" ]] || { usage; exit 1; }
    command -v terraform >/dev/null || { echo "Terraform 1.5+ is required." >&2; exit 1; }
    TOPOLOGY="$(read_tfvar topology "$TFVARS")"
    AGENT_LOCATION="$(read_tfvar agent_location "$TFVARS" eastus2)"
    SPLUNK_LOCATION="$(read_tfvar splunk_location "$TFVARS" "$AGENT_LOCATION")"
    AGENT_VNET="$(read_tfvar agent_vnet_address_prefix "$TFVARS" 10.100.0.0/16)"
    SPLUNK_VNET="$(read_tfvar splunk_vnet_address_prefix "$TFVARS" "$AGENT_VNET")"
    AGENT_SUBNET="$(read_tfvar agent_subnet_prefix "$TFVARS" 10.100.0.0/27)"
    SPLUNK_SUBNET="$(read_tfvar splunk_subnet_prefix "$TFVARS" 10.100.1.0/24)"
    PRIVATE_IP="$(read_tfvar splunk_private_ip "$TFVARS" 10.100.1.4)"
    SSH_KEY="$(read_tfvar admin_ssh_public_key "$TFVARS")"
    validate_deployment_inputs "$TOPOLOGY" "$AGENT_LOCATION" "$SPLUNK_LOCATION" "$AGENT_VNET" "$SPLUNK_VNET" "$AGENT_SUBNET" "$SPLUNK_SUBNET" "$PRIVATE_IP" "$SSH_KEY"
    TFVARS="$(cd "$(dirname "$TFVARS")" && pwd)/$(basename "$TFVARS")"
    terraform -chdir="$EXAMPLE_DIR/terraform" init
    terraform -chdir="$EXAMPLE_DIR/terraform" apply -var-file="$TFVARS"
    ;;
  *) echo "Backend must be bicep or terraform." >&2; usage; exit 1 ;;
esac
