#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=internal/lab-environment.sh
source "$script_dir/internal/lab-environment.sh"

require_command az
require_command azd
require_command jq
require_command curl

subscription="$(get_lab_value AZURE_SUBSCRIPTION_ID)"
resource_group="$(get_lab_value AZURE_RESOURCE_GROUP)"
template_file="$LAB_ROOT/agent-setup/main.bicep"
[[ -f "$template_file" ]] || fail 'The Part 2 agent template is missing. Add it before deploying.'

account_json="$(az account show --subscription "$subscription" --only-show-errors --output json 2>/dev/null)" ||
  fail 'Sign in to Azure CLI with access to the lab subscription.'
account_tenant="$(jq -er '.tenantId | select(type == "string" and length > 0)' <<<"$account_json" 2>/dev/null)" ||
  fail 'Unable to read the lab subscription account.'
account_type="$(jq -er '.user.type' <<<"$account_json" 2>/dev/null)" || fail 'Unable to read the lab subscription account.'
active_tenant="$(az account show --query tenantId --only-show-errors --output tsv 2>/dev/null)" ||
  fail 'Sign in as a user and select an Azure CLI account in the lab subscription tenant, then rerun.'
[[ "$account_type" == 'user' && "$active_tenant" == "$account_tenant" ]] ||
  fail 'Sign in as a user and select an Azure CLI account in the lab subscription tenant, then rerun.'

signed_in_user_id="$(az ad signed-in-user show --query id --only-show-errors --output tsv 2>/dev/null)" ||
  fail 'Unable to resolve the signed-in user in the lab subscription tenant.'
[[ "$signed_in_user_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  fail 'Azure CLI returned an invalid signed-in user ID.'
principal_id="$(get_lab_value AZURE_PRINCIPAL_ID true)"
if [[ -n "$principal_id" && "$(printf '%s' "$principal_id" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$signed_in_user_id" | tr '[:upper:]' '[:lower:]')" ]]; then
  fail 'AZURE_PRINCIPAL_ID differs from the signed-in user. Review the azd identity manually before deploying.'
fi
[[ -n "$principal_id" ]] || principal_id="$signed_in_user_id"

application_insights_id="$(get_lab_value APPLICATION_INSIGHTS_ID)"
expected_prefix="/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.Insights/components/"
normalized_insights="$(printf '%s' "$application_insights_id" | tr '[:upper:]' '[:lower:]')"
normalized_prefix="$(printf '%s' "$expected_prefix" | tr '[:upper:]' '[:lower:]')"
[[ "$normalized_insights" == "$normalized_prefix"* && "${application_insights_id#"$expected_prefix"}" =~ ^[A-Za-z0-9_.()\-]+$ ]] ||
  fail 'APPLICATION_INSIGHTS_ID must identify an Application Insights component in the lab resource group.'

parameters="$(jq -n \
  --arg location "$(get_lab_value AZURE_LOCATION)" \
  --arg namePrefix "$(get_lab_value LAB_NAME_PREFIX)" \
  --arg principalId "$principal_id" \
  --arg applicationInsightsName "${application_insights_id##*/}" \
  --arg checkoutAppId "$(get_lab_value CHECKOUT_APP_ID)" \
  --arg postgresServerId "$(get_lab_value POSTGRES_SERVER_ID)" \
  --arg networkSecurityGroupName "$(get_lab_value LAB_NSG_NAME)" \
  '{location:$location,namePrefix:$namePrefix,principalId:$principalId,applicationInsightsName:$applicationInsightsName,checkoutAppId:$checkoutAppId,postgresServerId:$postgresServerId,networkSecurityGroupName:$networkSecurityGroupName}')"
outputs="$(invoke_lab_deployment "$subscription" "$resource_group" 'field-level-up-agent' "$template_file" "$parameters")"

agent_name="$(jq -er '.agentName.value | select(type == "string" and length > 0)' <<<"$outputs")" || fail 'The agent deployment is missing output agentName. No azd values have been updated.'
agent_id="$(jq -er '.agentId.value | select(type == "string" and length > 0)' <<<"$outputs")" || fail 'The agent deployment is missing output agentId. No azd values have been updated.'
agent_url="$(jq -er '.agentUrl.value | select(type == "string" and length > 0)' <<<"$outputs")" || fail 'The agent deployment is missing output agentUrl. No azd values have been updated.'
agent_endpoint="$(jq -er '.agentEndpoint.value | select(type == "string" and length > 0)' <<<"$outputs")" || fail 'The agent deployment is missing output agentEndpoint. No azd values have been updated.'
expected_id="/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.App/agents/$agent_name"
[[ "$agent_name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ && "$(printf '%s' "$agent_id" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$expected_id" | tr '[:upper:]' '[:lower:]')" ]] ||
  fail 'The deployment returned an unexpected agent identity. No azd values have been updated.'

while IFS=$'\t' read -r name value; do
  azd -C "$LAB_ROOT" env set "$name" "$value" --no-prompt >/dev/null 2>&1 ||
    fail "Unable to save $name in azd. Review the environment before continuing."
done <<EOF
SRE_AGENT_NAME	$agent_name
SRE_AGENT_RESOURCE_ID	$agent_id
SRE_AGENT_URL	$agent_url
SRE_AGENT_ENDPOINT	$agent_endpoint
EOF

"$LAB_ROOT/agent-setup/apply-permissions.sh" --subscription-id "$subscription" --resource-id "$expected_id"
printf '%s\n' 'Agent deployment and permission setup completed. Verify source Code Access, then connect GitHub issue access and email manually before enabling incidents.'
