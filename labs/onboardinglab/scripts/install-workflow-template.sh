#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
renderer="$script_dir/internal/render-workflow-template.py"
apply_extras="$repo_root/sreagent-templates/bicep/apply-extras.sh"

usage() {
  echo 'Usage: ./scripts/install-workflow-template.sh --subscription <id> --agent-name <name> --template <path>' >&2
}

subscription=''
agent_name=''
template=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) subscription="${2:-}"; shift 2 ;;
    --agent-name) agent_name="${2:-}"; shift 2 ;;
    --template) template="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$subscription" && -n "$agent_name" && -n "$template" ]] || { usage; exit 2; }
[[ "$subscription" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
  echo 'Error: --subscription must be an Azure subscription ID' >&2
  exit 1
}
[[ "$agent_name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo 'Error: invalid --agent-name' >&2; exit 1; }
for command_name in az curl jq python3; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "Error: required command not found: $command_name" >&2; exit 1; }
done
[[ -f "$template" ]] || { echo "Error: template not found: $template" >&2; exit 1; }
[[ -x "$apply_extras" ]] || { echo "Error: shared extras installer not found: $apply_extras" >&2; exit 1; }

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/onboarding-workflow.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
extras_file="$temp_dir/workflow.extras.json"
agent_extras_file="$temp_dir/workflow-agent.extras.json"
python3 "$renderer" --template "$template" --output "$extras_file"

agents="$(az resource list --subscription "$subscription" --resource-type Microsoft.App/agents \
  --query "[?name=='$agent_name'].{id:id,resourceGroup:resourceGroup}" --output json)"
[[ "$(jq 'length' <<<"$agents")" -eq 1 ]] || {
  echo "Error: expected exactly one agent named $agent_name in subscription $subscription" >&2
  exit 1
}
resource_group="$(jq -r '.[0].resourceGroup' <<<"$agents")"
agent_id="$(jq -r '.[0].id' <<<"$agents")"
echo "  ok existing agent: $agent_name ($resource_group)"
agent_json="$(az rest --method GET --url "https://management.azure.com${agent_id}?api-version=2025-05-01-preview" --output json)"
endpoint="$(jq -r '.properties.agentEndpoint // empty' <<<"$agent_json")"
endpoint="${endpoint%/}"
platform="$(jq -r '.properties.incidentManagementConfiguration.type // empty' <<<"$agent_json")"
required_platform="$(jq -r '.installerRequirements.incidentPlatform' "$extras_file")"
[[ "$platform" == "$required_platform" ]] || { echo "Error: agent incident platform is $platform; expected $required_platform" >&2; exit 1; }
[[ "$endpoint" == https://* ]] || { echo 'Error: agent endpoint is unavailable' >&2; exit 1; }
echo "  ok incident platform: $platform"

connectors="$(az rest --method GET --url "https://management.azure.com${agent_id}/DataConnectors?api-version=2025-05-01-preview" --output json)"
minimum="$(jq -r '.installerRequirements.minimumTelemetryConnectors' "$extras_file")"
healthy="$(jq '[.value[]? | select(.properties.dataConnectorType == "AppInsights" or .properties.dataConnectorType == "LogAnalytics") | select(.properties.provisioningState == "Succeeded" or .properties.provisioningState == "Running")] | length' <<<"$connectors")"
[[ "$healthy" -ge "$minimum" ]] || { echo "Error: found $healthy healthy telemetry connectors; expected at least $minimum" >&2; exit 1; }
telemetry_tools="$(jq -c '[.value[]? | select(.properties.provisioningState == "Succeeded" or .properties.provisioningState == "Running") | .properties.dataConnectorType | if . == "AppInsights" then "QueryAppInsightsUsingAppId" elif . == "LogAnalytics" then "QueryLogAnalyticsByWorkspaceId" else empty end] | unique' <<<"$connectors")"
echo "  ok healthy telemetry connectors: $healthy"
echo "  ok telemetry query tools: $(jq -r 'join(", ")' <<<"$telemetry_tools")"
echo 'Workflow prerequisites validated.'
jq --argjson telemetryTools "$telemetry_tools" \
  '.subagents[0].spec.tools = (.subagents[0].spec.tools + $telemetryTools | unique)' \
  "$extras_file" >"$extras_file.tmp"
mv "$extras_file.tmp" "$extras_file"

jq '{skills, subagents, scheduledTasks}' "$extras_file" >"$agent_extras_file"

echo 'Installing workflow skills, subagent, and scheduled task...'
bash "$apply_extras" "$subscription" "$resource_group" "$agent_name" "$agent_extras_file"
echo 'Creating response plan and connecting it to the subagent...'
token="$(az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv)"
auth_header="Authorization: Bearer $token"
workflow_name="$(jq -r '.installerRequirements.workflowName' "$extras_file")"
custom_agent="$(jq -r '.installerRequirements.customAgentName' "$extras_file")"
response_plan_body="$(jq -c '.incidentFilters[0] | {name:.metadata.name,type:"IncidentFilter",tags:[],properties:.spec}' "$extras_file")"
response_plan_result="$temp_dir/response-plan-result.json"
response_plan_url="$endpoint/api/v2/extendedAgent/incidentFilters/$workflow_name"
response_plan_status="$(curl -sS -o "$response_plan_result" -w '%{http_code}' -X PUT "$response_plan_url" \
  -H "$auth_header" -H 'Content-Type: application/json' --data "$response_plan_body")"
if [[ ! "$response_plan_status" =~ ^2 ]]; then
  echo "Error: response plan $workflow_name was rejected (HTTP $response_plan_status):" >&2
  jq . "$response_plan_result" >&2 2>/dev/null || cat "$response_plan_result" >&2
  exit 1
fi
echo "  ok response plan: $workflow_name -> $custom_agent"

installed_agent="$(curl -fsS "$endpoint/api/v2/extendedAgent/agents/$custom_agent" -H "$auth_header")"
jq -e --arg name "$custom_agent" --argjson telemetryTools "$telemetry_tools" \
  --argjson deniedTools "$(jq '.installerRequirements.deniedTools' "$extras_file")" \
  '.name == $name and ($telemetryTools - .properties.tools | length) == 0 and ($deniedTools - .properties.tools | length) == ($deniedTools | length)' \
  <<<"$installed_agent" >/dev/null
while IFS= read -r skill; do
  curl -fsS "$endpoint/api/v2/extendedAgent/skills/$skill" -H "$auth_header" | jq -e --arg name "$skill" '.name == $name' >/dev/null
done < <(jq -r '.installerRequirements.skillNames[]' "$extras_file")
curl -fsS "$endpoint/api/v2/extendedAgent/incidentFilters/$workflow_name" -H "$auth_header" |
  jq -e --arg agent "$custom_agent" '.properties.handlingAgent == $agent and .properties.agentMode == "Review" and .properties.priorities == ["Sev1", "Sev2"]' >/dev/null
scheduled_task="$(jq -r '.installerRequirements.scheduledTaskName' "$extras_file")"
scheduled_task_schedule="$(jq -r '.installerRequirements.scheduledTaskSchedule' "$extras_file")"
curl -fsS "$endpoint/api/v2/extendedAgent/scheduledtasks" -H "$auth_header" |
  jq -e --arg name "$scheduled_task" --arg schedule "$scheduled_task_schedule" \
    '(.value // .) | any(.[]; .name == $name and .properties.cronExpression == $schedule and .properties.agentMode == "Review" and .properties.isEnabled == false)' >/dev/null

echo "Workflow $workflow_name installed with response plan $workflow_name connected to subagent $custom_agent and scheduled task $scheduled_task paused."