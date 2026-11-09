#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=internal/lab-environment.sh
source "$script_dir/internal/lab-environment.sh"

github_repository_url=''
email_connector_name=''
email_recipients=()
enable_incidents=false
confirm_connections_ready=false
alert_severity=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-repository-url) github_repository_url="${2:-}"; shift 2 ;;
    --email-recipient) email_recipients+=("${2:-}"); shift 2 ;;
    --email-connector-name) email_connector_name="${2:-}"; shift 2 ;;
    --enable-incidents) enable_incidents=true; shift ;;
    --confirm-connections-ready) confirm_connections_ready=true; shift ;;
    --alert-severity) alert_severity="${2:-}"; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

require_command az
require_command azd
require_command jq
require_command curl
[[ "$github_repository_url" =~ ^https://github\.com(:443)?/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*/?$ ]] ||
  fail 'Supply https://github.com/owner/repository without credentials, encoded segments, query or fragment.'
[[ ${#email_recipients[@]} -gt 0 ]] || fail 'Supply at least one --email-recipient.'
for recipient in "${email_recipients[@]}"; do
  [[ "$recipient" =~ ^[A-Za-z0-9.!#%+_=-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] ||
    fail 'Each --email-recipient must be a plain email address without a display name or whitespace.'
done
[[ -n "${email_connector_name//[[:space:]]/}" ]] || fail 'Supply the existing email connector name.'
[[ "$alert_severity" == '1' || "$alert_severity" == '2' ]] || fail 'Alert severity must be 1 or 2.'
if [[ "$enable_incidents" == 'true' && "$confirm_connections_ready" != 'true' ]]; then
  fail 'Before enabling incidents, verify telemetry, scanning, access, skills, delegation, and GitHub/email authentication; then pass --confirm-connections-ready. No OAuth setup is automated.'
fi

subscription="$(get_lab_value AZURE_SUBSCRIPTION_ID)"
resource_group="$(get_lab_value AZURE_RESOURCE_GROUP)"
agent_name="$(get_lab_value SRE_AGENT_NAME)"
agent_id="$(get_lab_value SRE_AGENT_RESOURCE_ID)"
expected_id="/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.App/agents/$agent_name"
[[ "$agent_name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ && "$(printf '%s' "$agent_id" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$expected_id" | tr '[:upper:]' '[:lower:]')" ]] ||
  fail 'The azd agent identity must belong to the lab subscription and resource group. Review the environment manually.'

recipients_json="$(printf '%s\n' "${email_recipients[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
parameters="$(jq -n \
  --arg sreAgentName "$agent_name" \
  --arg checkoutAppId "$(get_lab_value CHECKOUT_APP_ID)" \
  --arg postgresServerId "$(get_lab_value POSTGRES_SERVER_ID)" \
  --arg applicationInsightsId "$(get_lab_value APPLICATION_INSIGHTS_ID)" \
  --arg applicationInsightsAppId "$(get_lab_value APPLICATION_INSIGHTS_APP_ID)" \
  --arg githubRepositoryUrl "$github_repository_url" \
  --argjson emailRecipients "$recipients_json" \
  --arg emailConnectorName "$email_connector_name" \
  --arg namePrefix "$(get_lab_value LAB_NAME_PREFIX)" \
  --arg location "$(get_lab_value AZURE_LOCATION)" \
  --argjson enableIncidents "$enable_incidents" \
  --argjson alertSeverity "$alert_severity" \
  '{sreAgentName:$sreAgentName,checkoutAppId:$checkoutAppId,postgresServerId:$postgresServerId,applicationInsightsId:$applicationInsightsId,applicationInsightsAppId:$applicationInsightsAppId,githubRepositoryUrl:$githubRepositoryUrl,emailRecipients:$emailRecipients,emailConnectorName:$emailConnectorName,namePrefix:$namePrefix,location:$location,enableIncidents:$enableIncidents,alertSeverity:$alertSeverity}')"

if [[ "$enable_incidents" == 'true' ]]; then
  "$LAB_ROOT/agent-setup/apply-permissions.sh" --subscription-id "$subscription" --resource-id "$agent_id" --check-only
fi
invoke_lab_deployment "$subscription" "$resource_group" 'field-level-up-use-cases' "$LAB_ROOT/use-cases/main.bicep" "$parameters" >/dev/null
printf 'Use-case templates deployed. Incidents enabled: %s. No email or GitHub issue was sent by this script.\n' "$enable_incidents"
