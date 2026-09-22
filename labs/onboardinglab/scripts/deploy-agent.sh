#!/usr/bin/env bash
az login --identity --client-id "${1:?Usage: deploy-agent.sh UAMI_CLIENT_ID SUBSCRIPTION LAB_RG LOCATION NAME_PREFIX AGENT_NAME AGENT_IDENTITY_NAME WORKLOAD_OPTION}" --output none || exit $?

set -Eeo pipefail

if [[ $# -ne 8 ]]; then
  echo "Usage: $0 UAMI_CLIENT_ID SUBSCRIPTION LAB_RG LOCATION NAME_PREFIX AGENT_NAME AGENT_IDENTITY_NAME WORKLOAD_OPTION" >&2
  exit 2
fi

set -u

UAMI_CLIENT_ID="$1"
SUBSCRIPTION="$2"
LAB_RG="$3"
LOCATION="$4"
NAME_PREFIX="$5"
AGENT_NAME="$6"
AGENT_IDENTITY_NAME="$7"
WORKLOAD_OPTION="$8"
[[ "$WORKLOAD_OPTION" == "app-service" || "$WORKLOAD_OPTION" == "app-service-postgresql" ]] \
  || { echo "WORKLOAD_OPTION must be app-service or app-service-postgresql." >&2; exit 2; }

REQUESTED_WORKLOAD_OPTION="$(az group show \
  --subscription "$SUBSCRIPTION" \
  --name "$LAB_RG" \
  --query tags.onboardingLabRequestedWorkloadOption -o tsv)"
[[ -n "$REQUESTED_WORKLOAD_OPTION" ]] \
  || { echo "The lab resource group does not record a requested workload option. Rerun the current bootstrap before deployment." >&2; exit 2; }
[[ "$REQUESTED_WORKLOAD_OPTION" == "$WORKLOAD_OPTION" ]] \
  || { echo "WORKLOAD_OPTION $WORKLOAD_OPTION does not match bootstrap selection $REQUESTED_WORKLOAD_OPTION. Deployment stopped before making changes." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$LAB_ROOT/../.." && pwd)"
TEMPLATE="$LAB_ROOT/infra/main.arm.json"
APP_ROOT="$LAB_ROOT/ticketingapp-source/app"
RECIPE_ROOT="$LAB_ROOT/agent-recipe"
CONFIG_ROOT="/tmp/onboardinglab-agent"
EXTRAS_FILE="${CONFIG_ROOT}.extras.json"
FILTERED_EXTRAS_FILE="${CONFIG_ROOT}.runtime.extras.json"
POLICY_EXTRAS_FILE="${CONFIG_ROOT}.policy.extras.json"
PRE_POLICY_EXPECTED_ROOT="/tmp/onboardinglab-agent-pre-policy"
STAGED_EXPECTED_ROOT="/tmp/onboardinglab-agent-staged"
APP_ARCHIVE="/tmp/checkout-app.zip"
DEPLOYMENT_NAME="onboardinglab"
AGENT_API_VERSION="2025-05-01-preview"
READER_ROLE_ID="acdd72a7-3385-48ef-bd42-f606fba81ae7"
LOG_ANALYTICS_READER_ROLE_ID="73c42c96-874c-492b-b04d-ab87d138a893"
MONITORING_READER_ROLE_ID="43d0d8ad-25c7-4714-9337-8ba259a9fe05"
LOG_FILE="/tmp/onboardinglab-deploy.log"
CURRENT_STAGE="initialization"

status() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  status "FAILED during $CURRENT_STAGE: $*"
  status "Full execution log: $LOG_FILE"
  exit 1
}

on_error() {
  local exit_code="$1"
  local line_number="$2"
  local command="$3"

  trap - ERR
  status "FAILED during $CURRENT_STAGE."
  status "Exit code: $exit_code"
  status "Script line: $line_number"
  status "Command: $command"
  status "Full execution log: $LOG_FILE"
  exit "$exit_code"
}

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

require_command() {
  command -v "$1" >/dev/null || fail "Missing required command: $1"
}

wait_for_role_assignments() {
  local principal_id="$1"
  local principal_label="$2"
  local scope="$3"
  shift 3
  local required_role_ids=("$@")
  local deadline=$((SECONDS + 300))
  local assignments=""
  local missing=()
  local role_id=""

  while (( SECONDS < deadline )); do
    assignments="$(az role assignment list \
      --subscription "$SUBSCRIPTION" \
      --scope "$scope" \
      --query "[?principalId=='$principal_id'].{roleDefinitionId:roleDefinitionId,scope:scope}" \
      --output json)"
    missing=()
    for role_id in "${required_role_ids[@]}"; do
      if ! jq -e --arg role_id "$role_id" --arg scope "$scope" \
        'any(.[]; ((.roleDefinitionId | ascii_downcase) | endswith("/" + ($role_id | ascii_downcase))) and ((.scope | ascii_downcase) == ($scope | ascii_downcase)))' \
        <<<"$assignments" >/dev/null; then
        missing+=("$role_id")
      fi
    done
    if (( ${#missing[@]} == 0 )); then
      status "Permanent roles are visible for $principal_label."
      return 0
    fi
    status "Waiting for permanent RBAC propagation for $principal_label; missing role IDs: ${missing[*]}"
    sleep 15
  done

  fail "$principal_label is missing permanent role IDs after five minutes: ${missing[*]}"
}

poll_infrastructure_deployment() {
  local deadline=$((SECONDS + 3600))
  local last_state=""
  local state=""
  local resource_count=""

  while (( SECONDS < deadline )); do
    state="$(az deployment group show \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$LAB_RG" \
      --name "$DEPLOYMENT_NAME" \
      --query properties.provisioningState -o tsv)"
    resource_count="$(az resource list \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$LAB_RG" \
      --query 'length(@)' -o tsv)"

    if [[ "$state" != "$last_state" ]]; then
      status "Infrastructure deployment state: $state; resources visible: $resource_count"
      last_state="$state"
    else
      status "Infrastructure deployment still $state; resources visible: $resource_count"
    fi

    case "$state" in
      Succeeded) return 0 ;;
      Failed|Canceled)
        status "Failed infrastructure deployment operations:"
        az deployment operation group list \
          --subscription "$SUBSCRIPTION" \
          --resource-group "$LAB_RG" \
          --name "$DEPLOYMENT_NAME" \
          --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName,type:properties.targetResource.resourceType,status:properties.statusMessage}" \
          --output json || true
        return 1
        ;;
    esac
    sleep 20
  done

  fail "Infrastructure deployment did not reach a terminal state within 60 minutes."
}

infrastructure_failure_is_workspace_propagation() {
  az deployment operation group list \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$LAB_RG" \
    --name "$DEPLOYMENT_NAME" \
    --query "[?properties.provisioningState=='Failed'].{type:properties.targetResource.resourceType,message:properties.statusMessage.error.message}" \
    --output json |
    jq -e 'length > 0 and all(.[];
      (.type == "Microsoft.Insights/scheduledQueryRules") and
      ((.message // "") | ascii_downcase | contains("workspace could not be found")))' >/dev/null
}

start_infrastructure_deployment() {
  az deployment group create \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$LAB_RG" \
    --name "$DEPLOYMENT_NAME" \
    --template-file "$TEMPLATE" \
    --parameters \
      location="$LOCATION" \
      namePrefix="$NAME_PREFIX" \
      agentName="$AGENT_NAME" \
      agentIdentityName="$AGENT_IDENTITY_NAME" \
      workloadOption="$WORKLOAD_OPTION" \
    --no-wait \
    --output none
}

ensure_incident_platform() {
  local agent_url="https://management.azure.com/subscriptions/$SUBSCRIPTION/resourceGroups/$LAB_RG/providers/Microsoft.App/agents/$AGENT_NAME?api-version=$AGENT_API_VERSION"
  local incident_platform=""
  local state=""
  local deadline=0

  incident_platform="$(az rest --method get --url "$agent_url" --query properties.incidentManagementConfiguration.type -o tsv)"
  if [[ "$incident_platform" == "AzMonitor" ]]; then
    status "Azure Monitor incident platform is already configured."
    return
  fi

  status "Configuring the Azure Monitor incident platform."
  az rest \
    --method patch \
    --url "$agent_url" \
    --headers "Content-Type=application/json" \
    --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"}}}' \
    --output none

  deadline=$((SECONDS + 1200))
  while (( SECONDS < deadline )); do
    state="$(az rest --method get --url "$agent_url" --query properties.provisioningState -o tsv)"
    status "Agent provisioning state after incident-platform update: $state"
    case "$state" in
      Succeeded) return ;;
      Failed|Canceled) fail "Agent incident-platform update ended in state $state." ;;
    esac
    sleep 15
  done
  fail "Agent incident-platform update did not complete within 20 minutes."
}

wait_for_agent_endpoint() {
  local deadline=$((SECONDS + 600))
  local endpoint=""
  local state=""

  while (( SECONDS < deadline )); do
    endpoint="$(az resource show \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$LAB_RG" \
      --name "$AGENT_NAME" \
      --resource-type Microsoft.App/agents \
      --api-version "$AGENT_API_VERSION" \
      --query properties.agentEndpoint -o tsv)"
    state="$(az resource show \
      --subscription "$SUBSCRIPTION" \
      --resource-group "$LAB_RG" \
      --name "$AGENT_NAME" \
      --resource-type Microsoft.App/agents \
      --api-version "$AGENT_API_VERSION" \
      --query properties.provisioningState -o tsv)"
    if [[ -n "$endpoint" ]]; then
      AGENT_ENDPOINT="$endpoint"
      status "SRE Agent data-plane endpoint is available."
      return 0
    fi
    case "$state" in
      Failed|Canceled) fail "The SRE Agent reached $state before its data-plane endpoint became available." ;;
    esac
    status "Waiting for the SRE Agent data-plane endpoint; provisioning state: $state"
    sleep 15
  done

  fail "The SRE Agent data-plane endpoint was not available within 10 minutes."
}

get_latest_web_deployment() {
  az webapp log deployment list \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$LAB_RG" \
    --name "$CHECKOUT_APP_NAME" \
    --output json
}

web_deployment_is_active() {
  case "${1,,}" in
    0|1|2|pending|building|deploying|running|inprogress) return 0 ;;
    *) return 1 ;;
  esac
}

web_deployment_is_successful() {
  case "${1,,}" in
    4|success|succeeded) return 0 ;;
    *) return 1 ;;
  esac
}

web_deployment_is_failed() {
  case "${1,,}" in
    3|failed|canceled|cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

poll_web_deployment() {
  local prior_id="$1"
  local expect_new="$2"
  local deadline=$((SECONDS + 1800))
  local start_seconds=$SECONDS
  local latest=""
  local deployment_id=""
  local deployment_status=""
  local deployment_start=""
  local deployment_end=""
  local last_report=""

  while (( SECONDS < deadline )); do
    latest="$(get_latest_web_deployment)"
    deployment_id="$(jq -r '.[0].id // empty' <<<"$latest")"
    deployment_status="$(jq -r '.[0].status // empty | tostring' <<<"$latest")"
    deployment_start="$(jq -r '.[0].start_time // empty' <<<"$latest")"
    deployment_end="$(jq -r '.[0].end_time // empty' <<<"$latest")"

    if [[ -z "$deployment_id" ]]; then
      status "Waiting for OneDeploy to register the new asynchronous upload."
      sleep 15
      continue
    fi
    if [[ "$expect_new" == "true" && "$deployment_id" == "$prior_id" ]]; then
      if ! web_deployment_is_active "$deployment_status"; then
        status "Waiting for OneDeploy to replace or update the previous deployment record."
        sleep 15
        continue
      fi
    fi

    local report="$deployment_id|$deployment_status|$deployment_start|$deployment_end"
    if [[ "$report" != "$last_report" ]]; then
      status "OneDeploy id=$deployment_id status=$deployment_status elapsed=$((SECONDS - start_seconds))s start=$deployment_start end=$deployment_end"
      last_report="$report"
    else
      status "OneDeploy still status=$deployment_status elapsed=$((SECONDS - start_seconds))s"
    fi

    if web_deployment_is_successful "$deployment_status"; then
      return 0
    fi
    if web_deployment_is_failed "$deployment_status"; then
      status "Failed OneDeploy record:"
      jq '.[0]' <<<"$latest" || true
      az webapp log deployment show \
        --subscription "$SUBSCRIPTION" \
        --resource-group "$LAB_RG" \
        --name "$CHECKOUT_APP_NAME" \
        --output json || true
      return 1
    fi
    sleep 20
  done

  fail "OneDeploy did not reach a terminal state within 30 minutes."
}

status "Managed-identity login succeeded for client ID $UAMI_CLIENT_ID."
status "Writing the full execution log to $LOG_FILE."

for command_name in az git jq python3 pwsh curl tar; do
  require_command "$command_name"
done
python3 -c "import yaml" >/dev/null || fail "Missing Python module: PyYAML"

available_kb="$(df -Pk /tmp | awk 'NR==2 {print $4}')"
[[ "$available_kb" =~ ^[0-9]+$ ]] || fail "Could not determine free space in /tmp."
(( available_kb >= 51200 )) || fail "Less than 50 MiB is free in /tmp."

az account set --subscription "$SUBSCRIPTION"
active_subscription="$(az account show --query id -o tsv)"
[[ "$active_subscription" == "$SUBSCRIPTION" ]] || fail "Azure CLI selected subscription $active_subscription instead of $SUBSCRIPTION."
status "Using subscription $SUBSCRIPTION."

CURRENT_STAGE="identity and token validation"
identity_details="$(az identity show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$AGENT_IDENTITY_NAME" \
  --query '{clientId:clientId,principalId:principalId}' -o json)"
identity_client_id="$(jq -r '.clientId // empty' <<<"$identity_details")"
identity_principal_id="$(jq -r '.principalId // empty' <<<"$identity_details")"
[[ "$identity_client_id" == "$UAMI_CLIENT_ID" ]] || fail "The supplied client ID does not match $AGENT_IDENTITY_NAME."
[[ -n "$identity_principal_id" ]] || fail "The action identity has no principal ID."

az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv >/dev/null \
  || fail "The action identity could not acquire an SRE Agent data-plane token."
status "ARM and SRE Agent data-plane authentication succeeded."

CURRENT_STAGE="incident-platform configuration"
ensure_incident_platform

CURRENT_STAGE="regional preflight"
az group show \
  --subscription "$SUBSCRIPTION" \
  --name "$LAB_RG" \
  --query '{name:name,location:location,state:properties.provisioningState}' -o json

if [[ "$WORKLOAD_OPTION" == "app-service-postgresql" ]]; then
  capabilities="$(az postgres flexible-server list-skus \
    --subscription "$SUBSCRIPTION" \
    --location "$LOCATION" \
    --output json)"
  jq -e '[.[].supportedServerVersions[]?.name] | index("16") != null' <<<"$capabilities" >/dev/null \
    || fail "PostgreSQL version 16 is not advertised in $LOCATION. Choose the App Service option or use a subscription with the required Sweden Central capability. Reasons: $(jq -r '[.[].reason // empty] | unique | join("; ")' <<<"$capabilities")"
  jq -e '[.[].supportedServerEditions[]?.supportedServerSkus[]?.name] | index("Standard_B1ms") != null' <<<"$capabilities" >/dev/null \
    || fail "PostgreSQL Standard_B1ms is not advertised in $LOCATION. Choose the App Service option or use a subscription with the required Sweden Central capability. Reasons: $(jq -r '[.[].reason // empty] | unique | join("; ")' <<<"$capabilities")"
  status "Preflight passed for Azure SRE Agent and PostgreSQL 16 / Standard_B1ms in $LOCATION."
else
  status "Preflight passed for Azure SRE Agent and the App Service workload in $LOCATION."
fi

normalized_location="${LOCATION// /}"
normalized_location="${normalized_location,,}"
agent_provider="$(az provider show --subscription "$SUBSCRIPTION" --namespace Microsoft.App -o json)"
jq -e --arg location "$normalized_location" \
  '[.resourceTypes[] | select(.resourceType == "agents") | .locations[]? | ascii_downcase | gsub(" "; "")] | index($location) != null' \
  <<<"$agent_provider" >/dev/null || fail "Azure SRE Agent is not advertised in $LOCATION."
[[ -f "$TEMPLATE" ]] || fail "Compiled deployment template not found: $TEMPLATE"

CURRENT_STAGE="infrastructure deployment"
existing_deployment_state="$(az deployment group show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.provisioningState -o tsv 2>/dev/null || true)"

if [[ "$existing_deployment_state" == "Running" || "$existing_deployment_state" == "Accepted" ]]; then
  status "Infrastructure deployment is already $existing_deployment_state; monitoring the existing deployment."
else
  if [[ "$existing_deployment_state" == "Succeeded" ]]; then
    status "Infrastructure deployment previously succeeded; reconciling the current Bicep-authored template."
  else
    status "Starting asynchronous infrastructure deployment."
  fi
  start_infrastructure_deployment
fi

infrastructure_attempt=1
while ! poll_infrastructure_deployment; do
  if (( infrastructure_attempt >= 3 )) || ! infrastructure_failure_is_workspace_propagation; then
    fail "Infrastructure deployment failed. Inspect deployment operations before retrying."
  fi
  infrastructure_attempt=$((infrastructure_attempt + 1))
  retry_delay=$((infrastructure_attempt * 30))
  status "Azure Monitor has not resolved the new Log Analytics workspace. Retrying infrastructure deployment in ${retry_delay}s (attempt ${infrastructure_attempt}/3)."
  sleep "$retry_delay"
  start_infrastructure_deployment
done

deployment_outputs="$(az deployment group show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs -o json)"

CHECKOUT_APP_NAME="$(jq -r '.checkoutAppName.value // empty' <<<"$deployment_outputs")"
CHECKOUT_URL="$(jq -r '.checkoutUrl.value // empty' <<<"$deployment_outputs")"
APP_INSIGHTS_ID="$(jq -r '.applicationInsightsId.value // empty' <<<"$deployment_outputs")"
APP_INSIGHTS_APP_ID="$(jq -r '.applicationInsightsAppId.value // empty' <<<"$deployment_outputs")"
NETWORK_SECURITY_GROUP_NAME="$(jq -r '.networkSecurityGroupName.value // empty' <<<"$deployment_outputs")"
LOG_ANALYTICS_WORKSPACE_ID="$(jq -r '.logAnalyticsWorkspaceId.value // empty' <<<"$deployment_outputs")"
AGENT_ENDPOINT="$(jq -r '.agentEndpoint.value // empty' <<<"$deployment_outputs")"

for required_value in CHECKOUT_APP_NAME CHECKOUT_URL APP_INSIGHTS_ID APP_INSIGHTS_APP_ID LOG_ANALYTICS_WORKSPACE_ID; do
  [[ -n "${!required_value}" ]] || fail "Infrastructure output $required_value is empty."
done
CURRENT_STAGE="agent endpoint propagation"
wait_for_agent_endpoint
status "Infrastructure ready: app=$CHECKOUT_APP_NAME endpoint=$CHECKOUT_URL."

CURRENT_STAGE="application packaging"
status "Building the checkout application archive."
rm -f "$APP_ARCHIVE"
APP_ROOT="$APP_ROOT" APP_ARCHIVE="$APP_ARCHIVE" python3 - <<'PY'
import os
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

root = Path(os.environ["APP_ROOT"])
archive_path = Path(os.environ["APP_ARCHIVE"])
excluded = {"node_modules", "test", ".git"}
with ZipFile(archive_path, "w", ZIP_DEFLATED) as archive:
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if path.is_file() and not excluded.intersection(relative.parts):
            archive.write(path, relative)
PY

CURRENT_STAGE="application deployment"
latest_before="$(get_latest_web_deployment)"
prior_deployment_id="$(jq -r '.[0].id // empty' <<<"$latest_before")"
prior_deployment_status="$(jq -r '.[0].status // empty | tostring' <<<"$latest_before")"

if [[ -n "$prior_deployment_id" ]] && web_deployment_is_active "$prior_deployment_status"; then
  status "OneDeploy $prior_deployment_id is already active; monitoring it instead of uploading again."
  expect_new_web_deployment=false
elif [[ -n "$prior_deployment_id" ]] && web_deployment_is_successful "$prior_deployment_status"; then
  status "OneDeploy $prior_deployment_id already succeeded; reusing the completed application deployment."
  expect_new_web_deployment=false
else
  status "Submitting the checkout application to OneDeploy asynchronously."
  az webapp deploy \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$LAB_RG" \
    --name "$CHECKOUT_APP_NAME" \
    --type zip \
    --src-path "$APP_ARCHIVE" \
    --async true \
    --output none
  expect_new_web_deployment=true
fi

poll_web_deployment "$prior_deployment_id" "$expect_new_web_deployment" \
  || fail "OneDeploy failed. Inspect the existing deployment log before retrying."
status "OneDeploy reached a successful terminal state."
az webapp log deployment show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$CHECKOUT_APP_NAME" \
  --output json

CURRENT_STAGE="agent configuration generation"
status "Generating the onboarding agent configuration."
rm -rf "$CONFIG_ROOT" "$PRE_POLICY_EXPECTED_ROOT" "$STAGED_EXPECTED_ROOT"
rm -f "$EXTRAS_FILE" "$FILTERED_EXTRAS_FILE" "$POLICY_EXTRAS_FILE"

pwsh -NoProfile -File "$REPO_ROOT/sreagent-templates/bin/ps/New-Agent.ps1" \
  -RecipePath "$RECIPE_ROOT" \
  -Output "$CONFIG_ROOT" \
  -Subscription "$SUBSCRIPTION" \
  -NonInteractive \
  -NoTelemetry \
  -Set "agentName=$AGENT_NAME,resourceGroup=$LAB_RG,location=$LOCATION,appInsightsId=$APP_INSIGHTS_ID,appInsightsAppId=$APP_INSIGHTS_APP_ID,modelProvider=MicrosoftFoundry"

mkdir -p "$CONFIG_ROOT/config/connectorv2"
cp "$RECIPE_ROOT/optional/connectorv2/outlook.yaml" "$CONFIG_ROOT/config/connectorv2/outlook.yaml"
jq '.managedConnectors = ["office365"]' \
  "$CONFIG_ROOT/expected-config.json" > "$CONFIG_ROOT/expected-config.json.tmp"
mv "$CONFIG_ROOT/expected-config.json.tmp" "$CONFIG_ROOT/expected-config.json"
jq '
  .allow = ((.allow + ["ListOutlookEmails"]) | unique) |
  .ask = ((.ask + ["SendOutlookEmail"]) | unique)
' "$CONFIG_ROOT/tool-permissions.json" > "$CONFIG_ROOT/tool-permissions.json.tmp"
mv "$CONFIG_ROOT/tool-permissions.json.tmp" "$CONFIG_ROOT/tool-permissions.json"

pwsh -NoProfile -File "$REPO_ROOT/sreagent-templates/bicep/Assemble-Agent.ps1" \
  -ConfigDir "$CONFIG_ROOT" \
  -Output "$CONFIG_ROOT"

[[ -f "$EXTRAS_FILE" ]] || fail "Agent extras were not generated."
jq 'del(.incidentPlatforms, .toolPermissions)' "$EXTRAS_FILE" > "$FILTERED_EXTRAS_FILE"
jq '{toolPermissions}' "$EXTRAS_FILE" > "$POLICY_EXTRAS_FILE"
mkdir -p "$PRE_POLICY_EXPECTED_ROOT" "$STAGED_EXPECTED_ROOT"
jq '.agent.accessLevel = "High" | .agent.actionMode = "Review"' \
  "$CONFIG_ROOT/expected-config.json" > "$STAGED_EXPECTED_ROOT/expected-config.json"
jq 'del(.toolPermissions)' "$STAGED_EXPECTED_ROOT/expected-config.json" \
  > "$PRE_POLICY_EXPECTED_ROOT/expected-config.json"

CURRENT_STAGE="agent configuration apply"
status "Applying skills, knowledge, hooks, and prompts before the restrictive tool policy."
pwsh -NoProfile -File "$REPO_ROOT/sreagent-templates/bicep/Apply-Extras.ps1" \
  -Subscription "$SUBSCRIPTION" \
  -ResourceGroup "$LAB_RG" \
  -AgentName "$AGENT_NAME" \
  -ExtrasFile "$FILTERED_EXTRAS_FILE" \
  -Force

CURRENT_STAGE="agent configuration verification"
status "Verifying the configured SRE Agent before applying the restrictive tool policy."
pwsh -NoProfile -File "$REPO_ROOT/sreagent-templates/bin/ps/Verify-Agent.ps1" \
  -Subscription "$SUBSCRIPTION" \
  -ResourceGroup "$LAB_RG" \
  -AgentName "$AGENT_NAME" \
  -Expected "$PRE_POLICY_EXPECTED_ROOT"

agent_state="$(az resource show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$AGENT_NAME" \
  --resource-type Microsoft.App/agents \
  --api-version "$AGENT_API_VERSION" \
  --query properties.provisioningState -o tsv)"
incident_platform="$(az resource show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$AGENT_NAME" \
  --resource-type Microsoft.App/agents \
  --api-version "$AGENT_API_VERSION" \
  --query properties.incidentManagementConfiguration.type -o tsv)"
system_principal_id="$(az resource show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$AGENT_NAME" \
  --resource-type Microsoft.App/agents \
  --api-version "$AGENT_API_VERSION" \
  --query identity.principalId -o tsv)"
[[ "$agent_state" == "Succeeded" ]] || fail "Agent provisioning state is $agent_state."
[[ "$incident_platform" == "AzMonitor" ]] || fail "Agent incident platform is $incident_platform instead of AzMonitor."
[[ -n "$system_principal_id" ]] || fail "The SRE Agent has no system identity principal ID."

CURRENT_STAGE="permanent role verification"
lab_scope="/subscriptions/$SUBSCRIPTION/resourceGroups/$LAB_RG"
wait_for_role_assignments "$identity_principal_id" "action identity" "$lab_scope" \
  "$READER_ROLE_ID" "$MONITORING_READER_ROLE_ID" "$LOG_ANALYTICS_READER_ROLE_ID"
wait_for_role_assignments "$system_principal_id" "system identity" "$lab_scope" \
  "$READER_ROLE_ID" "$LOG_ANALYTICS_READER_ROLE_ID"
status "Permanent action-identity and system-identity roles are present."

alert_state="$(az monitor scheduled-query show \
  --subscription "$SUBSCRIPTION" \
  --resource-group "$LAB_RG" \
  --name "$NAME_PREFIX-checkout-failures" \
  --query '{enabled:enabled,severity:severity}' -o json)"
jq -e '.enabled == true and .severity == 2' <<<"$alert_state" >/dev/null \
  || fail "The checkout failure alert is not enabled at severity 2."

if [[ "$WORKLOAD_OPTION" == "app-service-postgresql" ]]; then
  [[ -n "$NETWORK_SECURITY_GROUP_NAME" ]] || fail "Infrastructure output NETWORK_SECURITY_GROUP_NAME is empty."
  fault_rule_access="$(az network nsg rule show \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$LAB_RG" \
    --nsg-name "$NETWORK_SECURITY_GROUP_NAME" \
    --name PostgreSqlFaultInjection \
    --query access -o tsv)"
  [[ "$fault_rule_access" == "Allow" ]] \
    || fail "The PostgreSqlFaultInjection rule is $fault_rule_access instead of Allow."
  status "Database fault rule is Allow."
else
  app_fault="$(az webapp config appsettings list \
    --subscription "$SUBSCRIPTION" \
    --resource-group "$LAB_RG" \
    --name "$CHECKOUT_APP_NAME" \
    --query "[?name=='APP_FAULT_ENABLED'].value | [0]" -o tsv)"
  [[ "$app_fault" == "false" ]] || fail "APP_FAULT_ENABLED is $app_fault instead of false."
  status "App Service fault is off."
fi

CURRENT_STAGE="application health verification"
status "Warming the application and verifying checkout."
for attempt in {1..10}; do
  http_code="$(curl -sS -m 90 -o /tmp/onboardinglab-checkout-response.json -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d '{"sku":"lab","qty":1}' "$CHECKOUT_URL/checkout" || true)"
  status "Checkout attempt $attempt returned HTTP $http_code."
  if [[ "$http_code" == "200" ]]; then
    break
  fi
  if [[ "$attempt" == "10" ]]; then
    fail "Checkout did not return HTTP 200 after 10 attempts."
  fi
  sleep 20
done

status "Waiting for Application Insights telemetry."
telemetry_found=false
for attempt in {1..8}; do
  telemetry="$(az monitor app-insights query \
    --subscription "$SUBSCRIPTION" \
    --app "$APP_INSIGHTS_APP_ID" \
    --analytics-query "requests | where timestamp > ago(30m) | summarize Total=count(), Failed=countif(success==false) by name, resultCode" \
    --output json)"
  row_count="$(jq '[.tables[]?.rows[]?] | length' <<<"$telemetry")"
  status "Telemetry check $attempt found $row_count result row(s)."
  if (( row_count > 0 )); then
    telemetry_found=true
    break
  fi
  sleep 30
done
[[ "$telemetry_found" == "true" ]] || fail "Application Insights returned no request telemetry after four minutes."

CURRENT_STAGE="durable tool-policy apply"
status "Applying the durable tool policy after workload and telemetry verification."
pwsh -NoProfile -File "$REPO_ROOT/sreagent-templates/bicep/Apply-Extras.ps1" \
  -Subscription "$SUBSCRIPTION" \
  -ResourceGroup "$LAB_RG" \
  -AgentName "$AGENT_NAME" \
  -ExtrasFile "$POLICY_EXTRAS_FILE" \
  -Force

CURRENT_STAGE="final agent configuration verification"
status "Verifying the final SRE Agent configuration, including tool policy."
pwsh -NoProfile -File "$REPO_ROOT/sreagent-templates/bin/ps/Verify-Agent.ps1" \
  -Subscription "$SUBSCRIPTION" \
  -ResourceGroup "$LAB_RG" \
  -AgentName "$AGENT_NAME" \
  -Expected "$STAGED_EXPECTED_ROOT"

CURRENT_STAGE="completion marker update"
status "Recording verified deployment completion."
az tag update \
  --resource-id "/subscriptions/$SUBSCRIPTION/resourceGroups/$LAB_RG" \
  --operation Merge \
  --tags onboardingLabDeploymentStatus=verified onboardingLabWorkloadOption="$WORKLOAD_OPTION" \
  --output none

marker="$(az group show \
  --subscription "$SUBSCRIPTION" \
  --name "$LAB_RG" \
  --query tags.onboardingLabDeploymentStatus -o tsv)"
[[ "$marker" == "verified" ]] || fail "The verified deployment marker was not written."

status "Deployment and verification completed successfully."
status "Checkout URL: $CHECKOUT_URL"
status "Agent URL: https://sre.azure.com/agents/subscriptions/$SUBSCRIPTION/resourceGroups/$LAB_RG/providers/Microsoft.App/agents/$AGENT_NAME"
status "External finalization is safe."
