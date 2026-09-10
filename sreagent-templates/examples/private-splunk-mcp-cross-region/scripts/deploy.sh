#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  deploy.sh bicep --resource-group <name> --parameters <file>
  deploy.sh terraform --tfvars <file>
EOF
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

case "$BACKEND" in
  bicep)
    [[ -n "$RESOURCE_GROUP" && -n "$PARAMETERS" ]] || { usage; exit 1; }
    [[ -f "$PARAMETERS" ]] || { echo "Parameters file not found: $PARAMETERS" >&2; exit 1; }
    command -v az >/dev/null || { echo "Azure CLI is required." >&2; exit 1; }
    LOCATION="$(jq -r '.parameters.agentLocation.value // "eastus2"' "$PARAMETERS")"
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
    az deployment group create \
      --resource-group "$RESOURCE_GROUP" \
      --name "private-splunk-$(date +%Y%m%d-%H%M%S)" \
      --template-file "$EXAMPLE_DIR/bicep/main.bicep" \
      --parameters "@$PARAMETERS" \
      --output json
    ;;
  terraform)
    [[ -n "$TFVARS" ]] || { usage; exit 1; }
    [[ -f "$TFVARS" ]] || { echo "tfvars file not found: $TFVARS" >&2; exit 1; }
    command -v terraform >/dev/null || { echo "Terraform 1.5+ is required." >&2; exit 1; }
    TFVARS="$(cd "$(dirname "$TFVARS")" && pwd)/$(basename "$TFVARS")"
    terraform -chdir="$EXAMPLE_DIR/terraform" init
    terraform -chdir="$EXAMPLE_DIR/terraform" apply -var-file="$TFVARS"
    ;;
  *)
    echo "Backend must be bicep or terraform." >&2
    usage
    exit 1
    ;;
esac
