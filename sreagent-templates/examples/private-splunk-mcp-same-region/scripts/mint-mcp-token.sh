#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: mint-mcp-token.sh --resource-group <rg> --vm-name <vm> [--scheme http|https] [--days <1-180>]" >&2
}

RESOURCE_GROUP=""
VM_NAME=""
SCHEME="https"
DAYS="7"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$RESOURCE_GROUP" && -n "$VM_NAME" ]] || { usage; exit 1; }
[[ "$SCHEME" == "http" || "$SCHEME" == "https" ]] || { echo "Scheme must be http or https." >&2; exit 1; }
[[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -ge 1 && "$DAYS" -le 180 ]] || { echo "Days must be between 1 and 180." >&2; exit 1; }

read -r -s -p "Splunk administrator password: " SPLUNK_PASSWORD
echo

VM_LOCATION="$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query location --output tsv)"
RUN_COMMAND_NAME="mint-splunk-mcp-token-$(date +%s)-${RANDOM}"

cleanup() {
  az vm run-command delete --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --yes >/dev/null 2>&1 || true
  unset SPLUNK_PASSWORD
}
trap cleanup EXIT

SCRIPT='set -euo pipefail
SPLUNK_PASSWORD=""
SCHEME="${scheme:-}"
DAYS="${days:-}"
if [[ -n "${splunkPasswordBase64:-}" ]]; then
  SPLUNK_PASSWORD="$(printf "%s" "$splunkPasswordBase64" | base64 -d)"
fi
for argument in "$@"; do
  case "$argument" in
    splunkPasswordBase64=*) SPLUNK_PASSWORD="$(printf '%s' "${argument#*=}" | base64 -d)" ;;
    scheme=*) SCHEME="${argument#*=}" ;;
    days=*) DAYS="${argument#*=}" ;;
  esac
done
response="$(curl -sk -u "admin:${SPLUNK_PASSWORD}" "${SCHEME}://127.0.0.1:8089/services/mcp_token?username=admin&expires_on=%2B${DAYS}d")"
python3 -c "import json,sys; data=json.load(sys.stdin); token=data.get(\"token\"); assert token, \"Token missing from response\"; print(token)" <<<"$response"'
SCRIPT_BASE64="$(printf '%s' "$SCRIPT" | base64 | tr -d '\r\n')"
RUN_COMMAND_SCRIPT="printf '%s' '$SCRIPT_BASE64' | base64 -d | bash -s -- \"\$@\""
SPLUNK_PASSWORD_BASE64="$(printf '%s' "$SPLUNK_PASSWORD" | base64 | tr -d '\r\n')"

az vm run-command create \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --location "$VM_LOCATION" \
  --run-command-name "$RUN_COMMAND_NAME" \
  --script "$RUN_COMMAND_SCRIPT" \
  --parameters "scheme=$SCHEME" "days=$DAYS" \
  --protected-parameters "splunkPasswordBase64=$SPLUNK_PASSWORD_BASE64" \
  --timeout-in-seconds 300 \
  --output none

RUN_COMMAND_EXIT_CODE="$(az vm run-command show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --instance-view --query instanceView.exitCode --output tsv)"
if [[ "$RUN_COMMAND_EXIT_CODE" != "0" ]]; then
  az vm run-command show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --instance-view --query instanceView.error --output tsv >&2
  echo "MCP token creation failed on the VM." >&2
  exit 1
fi

TOKEN="$(az vm run-command show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --instance-view --query instanceView.output --output tsv | tr -d '\r\n')"
[[ -n "$TOKEN" ]] || { echo "MCP token creation returned no token." >&2; exit 1; }

echo
echo "Encrypted MCP token (shown once; store it securely and do not commit it):"
echo "$TOKEN"
