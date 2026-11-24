#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=internal/lab-environment.sh
source "$script_dir/internal/lab-environment.sh"

action="${1:-}"
[[ $# -eq 1 && ("$action" == 'inject' || "$action" == 'reset') ]] || fail 'Usage: ./scripts/fault.sh inject|reset'
require_command az
require_command azd
require_command jq
require_command curl

authenticated_curl() {
  printf 'header = "Authorization: Bearer %s"\n' "$arm_token" | curl --config - "$@"
}

subscription="$(get_lab_value AZURE_SUBSCRIPTION_ID)"
resource_group="$(get_lab_value AZURE_RESOURCE_GROUP)"
nsg="$(get_lab_value LAB_NSG_NAME)"
inject_fault=false

if [[ "$action" == 'inject' ]]; then
  inject_fault=true
  alert_rule_name="$(get_lab_value LAB_NAME_PREFIX)-checkout-failures"
  alert_rule_id="/subscriptions/$subscription/resourceGroups/$resource_group/providers/microsoft.insights/scheduledqueryrules/$alert_rule_name"
  end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  start_time="$(date -u -v-7d '+%Y-%m-%dT%H:%M:%SZ')"
  arm_token="$(az account get-access-token --subscription "$subscription" --resource 'https://management.azure.com/' --query accessToken --only-show-errors --output tsv 2>/dev/null)" ||
    fail 'Unable to obtain an ARM token before injecting the fault.'
  [[ -n "${arm_token//[[:space:]]/}" ]] || fail 'Unable to obtain an ARM token before injecting the fault.'
  alerts="$(authenticated_curl --silent --show-error --fail --max-redirs 0 --get \
    --data-urlencode 'api-version=2019-03-01' \
    --data-urlencode "customTimeRange=$start_time/$end_time" \
    "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.AlertsManagement/alerts")" ||
    fail 'Unable to inspect prior checkout alerts before injecting the fault.'

  while IFS= read -r alert; do
    [[ -n "$alert" ]] || continue
    alert_state="$(jq -r '.properties.essentials.alertState' <<<"$alert")"
    monitor_condition="$(jq -r '.properties.essentials.monitorCondition' <<<"$alert")"
    [[ "$(printf '%s' "$alert_state" | tr '[:upper:]' '[:lower:]')" != 'closed' ]] || continue
    [[ "$(printf '%s' "$monitor_condition" | tr '[:upper:]' '[:lower:]')" == 'resolved' ]] ||
      fail 'A prior checkout alert is still fired. Reset the fault, generate successful traffic, and wait for the alert to resolve before reinjecting.'
    alert_id="$(jq -er '.id | select(type == "string" and startswith("/subscriptions/"))' <<<"$alert")" ||
      fail 'A prior checkout alert returned an invalid resource ID.'
    authenticated_curl --silent --show-error --fail --max-redirs 0 --request POST \
      --header 'Content-Type: application/json' \
      --data '{"comments":"Closed by the Azure SRE Agent Onboarding Lab fault helper before a new rehearsal."}' \
      "https://management.azure.com${alert_id}/changestate?api-version=2019-03-01&newState=Closed" >/dev/null ||
      fail 'Unable to close the prior checkout alert before injecting the fault.'
  done < <(jq -c --arg rule "$alert_rule_id" '.value[]? | select((.properties.essentials.alertRule | ascii_downcase) == ($rule | ascii_downcase))' <<<"$alerts")
  arm_token=''
fi

az deployment group create \
  --subscription "$subscription" \
  --resource-group "$resource_group" \
  --name field-level-up-fault \
  --template-file "$LAB_ROOT/fault.bicep" \
  --parameters "networkSecurityGroupName=$nsg" "injectDatabaseFault=$inject_fault" \
  --output none || fail 'Fault rule deployment failed.'
printf 'Fault %s completed. Generate new checkout traffic to verify the result.\n' "$action"
