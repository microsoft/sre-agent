#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure-splunk.sh --resource-group <rg> --vm-name <vm> --package <path> [--acr-name <acr>] [--enable-lab-http]

Installs Docker, Splunk Enterprise, and a user-downloaded MCP Server for Splunk
Platform package on the private VM. Secrets are passed through protected Azure
VM Run Command parameters and are not written to Terraform state or ARM outputs.
EOF
}

RESOURCE_GROUP=""
VM_NAME=""
PACKAGE_PATH=""
ACR_NAME=""
ENABLE_LAB_HTTP="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --package) PACKAGE_PATH="$2"; shift 2 ;;
    --acr-name) ACR_NAME="$2"; shift 2 ;;
    --enable-lab-http) ENABLE_LAB_HTTP="true"; shift ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$RESOURCE_GROUP" && -n "$VM_NAME" && -n "$PACKAGE_PATH" ]] || { usage; exit 1; }
[[ -f "$PACKAGE_PATH" ]] || { echo "MCP package not found: $PACKAGE_PATH" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v sha256sum >/dev/null 2>&1; then
  TRANSFER_ID="$(printf '%s' "${RESOURCE_GROUP}-${VM_NAME}-$(date +%s)-${RANDOM}" | sha256sum | cut -c1-13)"
else
  TRANSFER_ID="$(printf '%s' "${RESOURCE_GROUP}-${VM_NAME}-$(date +%s)-${RANDOM}" | shasum -a 256 | cut -c1-13)"
fi
STORAGE_ACCOUNT="stsplunk${TRANSFER_ID}"
CONTAINER_NAME="packages"
BLOB_NAME="$(basename "$PACKAGE_PATH")"
RUN_COMMAND_NAME="configure-private-splunk-${TRANSFER_ID}"

read -r -s -p "Splunk administrator password: " SPLUNK_PASSWORD
echo

cleanup() {
  az vm run-command delete --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --yes >/dev/null 2>&1 || true
  az storage account delete --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" --yes >/dev/null 2>&1 || true
  unset SPLUNK_PASSWORD REGISTRY_PASSWORD PACKAGE_URL
}
trap cleanup EXIT

VM_LOCATION="$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query location --output tsv)"
az storage account create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" \
  --location "$VM_LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --output none

AZURE_STORAGE_KEY="$(az storage account keys list --resource-group "$RESOURCE_GROUP" --account-name "$STORAGE_ACCOUNT" --query '[0].value' --output tsv)"
[[ -n "$AZURE_STORAGE_KEY" ]] || { echo "Unable to retrieve the temporary storage account key." >&2; exit 1; }

AZURE_STORAGE_KEY="$AZURE_STORAGE_KEY" az storage container create --account-name "$STORAGE_ACCOUNT" --name "$CONTAINER_NAME" --auth-mode key --output none
AZURE_STORAGE_KEY="$AZURE_STORAGE_KEY" az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER_NAME" \
  --name "$BLOB_NAME" \
  --file "$PACKAGE_PATH" \
  --auth-mode key \
  --overwrite \
  --output none

EXPIRY="$(date -u -d '1 hour' '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%MZ')"
PACKAGE_SAS="$(AZURE_STORAGE_KEY="$AZURE_STORAGE_KEY" az storage blob generate-sas \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER_NAME" \
  --name "$BLOB_NAME" \
  --permissions r \
  --expiry "$EXPIRY" \
  --https-only \
  --auth-mode key \
  --output tsv)"
PACKAGE_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}/${BLOB_NAME}?${PACKAGE_SAS}"

PROTECTED_PARAMETERS=("splunkPassword=$SPLUNK_PASSWORD" "packageUrl=$PACKAGE_URL")
PARAMETERS=("enableLabHttp=$ENABLE_LAB_HTTP")
if [[ -n "$ACR_NAME" ]]; then
  REGISTRY_SERVER="$(az acr show --name "$ACR_NAME" --query loginServer --output tsv)"
  REGISTRY_USERNAME="$(az acr credential show --name "$ACR_NAME" --query username --output tsv)"
  REGISTRY_PASSWORD="$(az acr credential show --name "$ACR_NAME" --query 'passwords[0].value' --output tsv)"
  PROTECTED_PARAMETERS+=("registryServer=$REGISTRY_SERVER" "registryUsername=$REGISTRY_USERNAME" "registryPassword=$REGISTRY_PASSWORD")
fi

az vm run-command create \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --location "$VM_LOCATION" \
  --run-command-name "$RUN_COMMAND_NAME" \
  --script "$(cat "$SCRIPT_DIR/vm-bootstrap.sh")" \
  --parameters "${PARAMETERS[@]}" \
  --protected-parameters "${PROTECTED_PARAMETERS[@]}" \
  --timeout-in-seconds 1800 \
  --output none

echo "Splunk and the MCP app are installed."
if [[ "$ENABLE_LAB_HTTP" == "true" ]]; then
  echo "WARNING: Splunk MCP is using plaintext HTTP inside the isolated private lab."
fi
echo "Next: validate the private route, mint an encrypted MCP token, and configure the SRE Agent connector as described in README.md."
