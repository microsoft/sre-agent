#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: mint-mcp-token.sh --resource-group <rg> --vm-name <vm> [--scheme http|https] [--days <1-180>] [--username <Splunk user>]" >&2
}

RESOURCE_GROUP=""
VM_NAME=""
SCHEME="https"
DAYS="7"
USERNAME="admin"
VM_LOCATION=""
RUN_COMMAND_NAME=""
RUN_COMMAND_ATTEMPTED=false
RUN_COMMAND_CREATED=false
TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --username) USERNAME="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$RESOURCE_GROUP" && -n "$VM_NAME" ]] || { usage; exit 1; }
[[ "$SCHEME" == "http" || "$SCHEME" == "https" ]] || { echo "Scheme must be http or https." >&2; exit 1; }
[[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -ge 1 && "$DAYS" -le 180 ]] || { echo "Days must be between 1 and 180." >&2; exit 1; }
[[ -n "$USERNAME" ]] || { echo "Username must not be empty." >&2; exit 1; }

cleanup_run_command() {
  [[ "$RUN_COMMAND_ATTEMPTED" == true ]] || return 0

  local scrubbed=false
  local deleted=false
  local output=""
  local resource_exists="$RUN_COMMAND_CREATED"

  if [[ "$resource_exists" != true ]]; then
    if output="$(az vm run-command show \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$VM_NAME" \
      --run-command-name "$RUN_COMMAND_NAME" \
      --instance-view \
      --output none 2>&1)"; then
      resource_exists=true
    elif grep -Eqi 'ResourceNotFound|could not be found' <<<"$output"; then
      return 0
    fi
  fi

  if [[ "$resource_exists" == true ]]; then
    if az vm run-command create \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$VM_NAME" \
      --location "$VM_LOCATION" \
      --run-command-name "$RUN_COMMAND_NAME" \
      --script "true" \
      --timeout-in-seconds 60 \
      --output none >/dev/null 2>&1; then
      scrubbed=true
    fi
  fi

  for attempt in 1 2 3; do
    if output="$(az vm run-command delete \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$VM_NAME" \
      --run-command-name "$RUN_COMMAND_NAME" \
      --yes 2>&1)"; then
      deleted=true
      break
    fi

    if grep -Eqi 'ResourceNotFound|could not be found' <<<"$output"; then
      deleted=true
      break
    fi

    [[ "$attempt" -eq 3 ]] || sleep $((attempt * 5))
  done

  if [[ "$deleted" == true ]]; then
    if output="$(az vm run-command show \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$VM_NAME" \
      --run-command-name "$RUN_COMMAND_NAME" \
      --instance-view \
      --output none 2>&1)"; then
      deleted=false
    elif ! grep -Eqi 'ResourceNotFound|could not be found' <<<"$output"; then
      deleted=false
    fi
  fi

  [[ "$deleted" == true ]] && return 0

  echo "WARNING: Managed Run Command cleanup failed for '$RUN_COMMAND_NAME' on VM '$VM_NAME' in resource group '$RESOURCE_GROUP'." >&2
  echo "Delete it manually: az vm run-command delete --resource-group '$RESOURCE_GROUP' --vm-name '$VM_NAME' --run-command-name '$RUN_COMMAND_NAME' --yes" >&2
  if [[ "$scrubbed" != true ]]; then
    echo "The command output could still contain the minted token. Treat it as compromised and revoke or replace it before retrying." >&2
  fi
  return 3
}

on_exit() {
  local original_status=$?
  local cleanup_status=0
  trap - EXIT
  set +e
  cleanup_run_command
  cleanup_status=$?
  unset SPLUNK_PASSWORD SPLUNK_PASSWORD_BASE64
  TOKEN=""

  if [[ "$original_status" -ne 0 ]]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

read -r -s -p "Splunk administrator password: " SPLUNK_PASSWORD
echo

VM_LOCATION="$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query location --output tsv)"
RUN_COMMAND_NAME="mint-splunk-mcp-token-$(date +%s)-${RANDOM}"

SCRIPT='set -euo pipefail
SPLUNK_PASSWORD=""
SCHEME="${scheme:-}"
DAYS="${days:-}"
TOKEN_USERNAME="${username:-admin}"
if [[ -n "${splunkPasswordBase64:-}" ]]; then
  SPLUNK_PASSWORD="$(printf "%s" "$splunkPasswordBase64" | base64 -d)"
fi
for argument in "$@"; do
  case "$argument" in
    splunkPasswordBase64=*) SPLUNK_PASSWORD="$(printf '%s' "${argument#*=}" | base64 -d)" ;;
    scheme=*) SCHEME="${argument#*=}" ;;
    days=*) DAYS="${argument#*=}" ;;
    username=*) TOKEN_USERNAME="${argument#*=}" ;;
  esac
done
response="$(curl -sk -u "admin:${SPLUNK_PASSWORD}" --get \
  --data-urlencode "username=${TOKEN_USERNAME}" \
  --data-urlencode "expires_on=+${DAYS}d" \
  "${SCHEME}://127.0.0.1:8089/services/mcp_token")"
python3 -c "import json,sys; data=json.load(sys.stdin); token=data.get(\"token\"); assert token, \"Token missing from response\"; print(token)" <<<"$response"'
SCRIPT_BASE64="$(printf '%s' "$SCRIPT" | base64 | tr -d '\r\n')"
RUN_COMMAND_SCRIPT="printf '%s' '$SCRIPT_BASE64' | base64 -d | bash -s -- \"\$@\""
SPLUNK_PASSWORD_BASE64="$(printf '%s' "$SPLUNK_PASSWORD" | base64 | tr -d '\r\n')"

RUN_COMMAND_ATTEMPTED=true
az vm run-command create \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --location "$VM_LOCATION" \
  --run-command-name "$RUN_COMMAND_NAME" \
  --script "$RUN_COMMAND_SCRIPT" \
  --parameters "scheme=$SCHEME" "days=$DAYS" "username=$USERNAME" \
  --protected-parameters "splunkPasswordBase64=$SPLUNK_PASSWORD_BASE64" \
  --timeout-in-seconds 300 \
  --output none
RUN_COMMAND_CREATED=true

RUN_COMMAND_EXIT_CODE="$(az vm run-command show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --instance-view --query instanceView.exitCode --output tsv)"
if [[ "$RUN_COMMAND_EXIT_CODE" != "0" ]]; then
  az vm run-command show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --instance-view --query instanceView.error --output tsv >&2
  echo "MCP token creation failed on the VM." >&2
  exit 1
fi

TOKEN="$(az vm run-command show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --run-command-name "$RUN_COMMAND_NAME" --instance-view --query instanceView.output --output tsv | tr -d '\r\n')"
[[ -n "$TOKEN" ]] || { echo "MCP token creation returned no token." >&2; exit 1; }

trap - EXIT
set +e
cleanup_run_command
CLEANUP_STATUS=$?
set -e
unset SPLUNK_PASSWORD SPLUNK_PASSWORD_BASE64
[[ "$CLEANUP_STATUS" -eq 0 ]] || exit "$CLEANUP_STATUS"

echo
echo "Encrypted MCP token (shown once; store it securely and do not commit it):"
echo "$TOKEN"
TOKEN=""
