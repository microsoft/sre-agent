#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=internal/lab-environment.sh
source "$script_dir/internal/lab-environment.sh"

action="${1:-}"
shift || true
subscription=''
resource_group=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) subscription="${2:-}"; shift 2 ;;
    --resource-group) resource_group="${2:-}"; shift 2 ;;
    *) fail 'Usage: ./scripts/fault.sh inject|reset [--subscription ID --resource-group NAME]' ;;
  esac
done
[[ "$action" == 'inject' || "$action" == 'reset' ]] || fail 'Usage: ./scripts/fault.sh inject|reset [--subscription ID --resource-group NAME]'
require_command az
require_command jq
require_command curl

authenticated_curl() {
  printf 'header = "Authorization: Bearer %s"\n' "$arm_token" | curl --config - "$@"
}

if [[ -z "$subscription" || -z "$resource_group" ]]; then
  require_command azd
  subscription="${subscription:-$(get_lab_value AZURE_SUBSCRIPTION_ID)}"
  resource_group="${resource_group:-$(get_lab_value AZURE_RESOURCE_GROUP)}"
fi
workload_option="$(az group show --subscription "$subscription" --name "$resource_group" --query tags.onboardingLabWorkloadOption -o tsv)"
if [[ -z "$workload_option" ]] && command -v azd >/dev/null 2>&1; then
  workload_option="$(get_lab_value LAB_WORKLOAD_OPTION true)"
fi
[[ "$workload_option" == 'app-service' || "$workload_option" == 'app-service-postgresql' ]] ||
  fail "Unsupported LAB_WORKLOAD_OPTION: $workload_option"
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

if [[ "$workload_option" == 'app-service' ]]; then
  app_name="$(az webapp list --subscription "$subscription" --resource-group "$resource_group" --query "[?tags.workloadOption=='app-service'].name | [0]" -o tsv)"
  [[ -n "$app_name" ]] || fail 'Could not discover the App Service checkout app.'
  az webapp config appsettings set \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    --name "$app_name" \
    --settings "APP_FAULT_ENABLED=$inject_fault" \
    --output none || fail 'App Service fault update failed.'
else
  nsg="$(az network nsg list --subscription "$subscription" --resource-group "$resource_group" --query "[?contains(name, '-app-nsg')].name | [0]" -o tsv)"
  [[ -n "$nsg" ]] || fail 'Could not discover the PostgreSQL fault NSG.'
  az deployment group create \
    --subscription "$subscription" \
    --resource-group "$resource_group" \
    --name onboardinglab-fault \
    --template-file "$LAB_ROOT/fault.bicep" \
    --parameters "networkSecurityGroupName=$nsg" "injectDatabaseFault=$inject_fault" \
    --output none || fail 'Database fault rule deployment failed.'
fi
printf 'Fault %s completed. Generate new checkout traffic to verify the result.\n' "$action"
