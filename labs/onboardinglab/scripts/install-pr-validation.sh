#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
renderer="$script_dir/internal/render-pr-validation-template.py"
apply_extras="$repo_root/sreagent-templates/bicep/apply-extras.sh"

usage() {
  echo 'Usage: ./scripts/install-pr-validation.sh --subscription <id> --agent-name <name> --template <path>' >&2
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
python3 -c 'import yaml' 2>/dev/null || { echo 'Error: Python 3 with PyYAML is required' >&2; exit 1; }
[[ -f "$template" && -f "$renderer" && -x "$apply_extras" ]] || { echo 'Error: a required installer file is missing' >&2; exit 1; }

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/onboarding-pr-validation.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
extras_file="$temp_dir/pr-validation.extras.json"
agent_extras_file="$temp_dir/pr-validation-agent.extras.json"
trigger_extras_file="$temp_dir/pr-validation-trigger.extras.json"
python3 "$renderer" --template "$template" --output "$extras_file"

agents="$(az resource list --subscription "$subscription" --resource-type Microsoft.App/agents \
  --query "[?name=='$agent_name'].{id:id,resourceGroup:resourceGroup}" --output json)"
[[ "$(jq 'length' <<<"$agents")" -eq 1 ]] || { echo "Error: expected exactly one agent named $agent_name" >&2; exit 1; }
resource_group="$(jq -r '.[0].resourceGroup' <<<"$agents")"
agent_id="$(jq -r '.[0].id' <<<"$agents")"
agent_json="$(az rest --method GET --url "https://management.azure.com${agent_id}?api-version=2025-05-01-preview" --output json)"
endpoint="$(jq -r '.properties.agentEndpoint // empty' <<<"$agent_json")"
endpoint="${endpoint%/}"
[[ "$endpoint" == https://* ]] || { echo 'Error: agent endpoint is unavailable' >&2; exit 1; }

connectors="$(az rest --method GET --url "https://management.azure.com${agent_id}/DataConnectors?api-version=2025-05-01-preview" --output json)"
telemetry_tools="$(jq -c '[.value[]? | select(.properties.provisioningState == "Succeeded" or .properties.provisioningState == "Running") | .properties.dataConnectorType | if . == "AppInsights" then "QueryAppInsightsUsingAppId" elif . == "LogAnalytics" then "QueryLogAnalyticsByWorkspaceId" else empty end] | unique' <<<"$connectors")"
jq --argjson telemetryTools "$telemetry_tools" \
  '.subagents[0].spec.tools = (.subagents[0].spec.tools + $telemetryTools | unique)' \
  "$extras_file" >"$extras_file.tmp"
mv "$extras_file.tmp" "$extras_file"

jq '{skills, subagents}' "$extras_file" >"$agent_extras_file"
echo 'Installing Scenario 3 skill and PR validator...'
bash "$apply_extras" "$subscription" "$resource_group" "$agent_name" "$agent_extras_file"
jq '{httpTriggers, enableWebhookBridge}' "$extras_file" >"$trigger_extras_file"
echo 'Installing Scenario 3 HTTP trigger and webhook bridge...'
bash "$apply_extras" "$subscription" "$resource_group" "$agent_name" "$trigger_extras_file"

token="$(az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv)"
auth_header="Authorization: Bearer $token"
expected_agent="$(jq -r '.installerRequirements.agentName' "$extras_file")"
expected_skill="$(jq -r '.installerRequirements.skillName' "$extras_file")"
expected_trigger="$(jq -r '.installerRequirements.triggerName' "$extras_file")"
expected_tools="$(jq '.subagents[0].spec.tools' "$extras_file")"

curl -fsS "$endpoint/api/v2/extendedAgent/agents/$expected_agent" -H "$auth_header" |
  jq -e --arg name "$expected_agent" --arg skill "$expected_skill" --argjson tools "$expected_tools" \
    '.name == $name and ($tools - .properties.tools | length) == 0 and (.properties.allowedSkills | index($skill)) != null' >/dev/null
curl -fsS "$endpoint/api/v2/extendedAgent/skills/$expected_skill" -H "$auth_header" |
  jq -e --arg name "$expected_skill" '.name == $name' >/dev/null
curl -fsS "$endpoint/api/v1/httpTriggers" -H "$auth_header" |
  jq -e --arg name "$expected_trigger" --arg agent "$expected_agent" \
    '(.value // .) | any(.[]; .name == $name and .agent == $agent and .agentMode == "Review")' >/dev/null

logic_app_name="${agent_name}-webhook-bridge"
[[ "$(az resource list --subscription "$subscription" --resource-group "$resource_group" --resource-type Microsoft.Logic/workflows --query "[?name=='$logic_app_name'] | length(@)" --output tsv)" == '1' ]] || {
  echo "Error: webhook bridge verification failed: $logic_app_name" >&2
  exit 1
}
callback_url="$(az rest --method POST --url "/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.Logic/workflows/$logic_app_name/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" --query value --output tsv)"
[[ "$callback_url" == https://* ]] || { echo 'Error: webhook callback URL verification failed' >&2; exit 1; }

echo "Scenario 3 installed: $expected_trigger -> $expected_agent (Review)."
echo 'Store this callback URL as the GitHub Actions secret SRE_AGENT_WEBHOOK_URL:'
echo "  $callback_url"