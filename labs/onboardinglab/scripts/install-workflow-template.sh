#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
renderer="$script_dir/internal/render-workflow-template.py"
apply_extras="$repo_root/sreagent-templates/bicep/apply-extras.sh"

usage() {
  echo 'Usage: ./scripts/install-workflow-template.sh --subscription <id> --agent-name <name> --template <path> [--enable-source-code] [--enable-github-issues] [--github-repository https://github.com/owner/repo] [--enable-email --email-recipients user@example.com]' >&2
}

subscription=''
agent_name=''
template=''
enable_source_code=false
enable_github_issues=false
enable_email=false
renderer_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription|--agent-name|--template|--github-repository|--email-recipients)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage; exit 2; } ;;
  esac
  case "$1" in
    --subscription) subscription="${2:-}"; shift 2 ;;
    --agent-name) agent_name="${2:-}"; shift 2 ;;
    --template) template="${2:-}"; shift 2 ;;
    --enable-source-code) enable_source_code=true; renderer_args+=("$1"); shift ;;
    --enable-github-issues) enable_github_issues=true; renderer_args+=("$1"); shift ;;
    --enable-email) enable_email=true; renderer_args+=("$1"); shift ;;
    --github-repository|--email-recipients) renderer_args+=("$1" "$2"); shift 2 ;;
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
renderer_args+=(--template "$template" --output "$extras_file")
python3 "$renderer" "${renderer_args[@]}"

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
[[ "$endpoint" == https://* ]] || { echo 'Error: agent endpoint is unavailable' >&2; exit 1; }

connectors="$(az rest --method GET --url "https://management.azure.com${agent_id}/DataConnectors?api-version=2025-05-01-preview" --output json)"
token="$(az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv)"
[[ -n "$token" ]] || { echo 'Error: SRE Agent data-plane token is unavailable' >&2; exit 1; }
auth_header="Authorization: Bearer $token"
repos='null'
github_domains='null'
managed_connectors='null'
email_connection='null'
if [[ "$enable_source_code" == true || "$enable_github_issues" == true ]]; then
  repos="$(curl -fsS --max-time 30 "$endpoint/api/v2/repos" -H "$auth_header")"
  github_domains="$(curl -fsS --max-time 30 "$endpoint/api/v2/github/domains" -H "$auth_header")"
fi
if [[ "$enable_email" == true ]]; then
  managed_connectors="$(curl -fsS --max-time 30 "$endpoint/api/v2/connectorV2/mcpservers" -H "$auth_header")"
  email_connection="$(curl -fsS --max-time 30 "$endpoint/api/v2/connectorV2/connections/office365" -H "$auth_header")"
fi
state_file="$temp_dir/prerequisites.json"
jq -n --argjson agent "$agent_json" --argjson connectors "$connectors" --argjson repos "$repos" \
  --argjson githubDomains "$github_domains" --argjson managedConnectors "$managed_connectors" \
  --argjson emailConnection "$email_connection" \
  '{agent:$agent, connectors:$connectors, repos:$repos, githubDomains:$githubDomains, managedConnectors:$managedConnectors, emailConnection:$emailConnection}' >"$state_file"
python3 "$renderer" "${renderer_args[@]}" --prerequisite-state "$state_file"
echo 'Workflow prerequisites validated.'

jq '{skills, subagents}' "$extras_file" >"$agent_extras_file"

echo 'Installing workflow skills and subagent...'
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
jq -e --arg name "$custom_agent" --argjson expectedTools "$(jq '.subagents[0].spec.tools' "$extras_file")" \
  --argjson expectedSkills "$(jq '.installerRequirements.skillNames' "$extras_file")" \
  --argjson deniedTools "$(jq '.installerRequirements.deniedTools' "$extras_file")" \
  '.name == $name and (.properties.tools | sort) == ($expectedTools | sort) and (.properties.allowedSkills | sort) == ($expectedSkills | sort) and ($deniedTools - .properties.tools | length) == ($deniedTools | length)' \
  <<<"$installed_agent" >/dev/null
while IFS= read -r skill; do
  curl -fsS "$endpoint/api/v2/extendedAgent/skills/$skill" -H "$auth_header" | jq -e --arg name "$skill" '.name == $name' >/dev/null
done < <(jq -r '.installerRequirements.skillNames[]' "$extras_file")
curl -fsS "$endpoint/api/v2/extendedAgent/incidentFilters/$workflow_name" -H "$auth_header" |
  jq -e --argjson expected "$(jq '.incidentFilters[0].spec' "$extras_file")" \
    '.properties as $actual | ["handlingAgent","agentMode","priorities","titleContains","isEnabled","mergeEnabled","mergeWindowHours"] | all(.[]; $actual[.] == $expected[.])' >/dev/null

echo "Workflow $workflow_name installed with response plan $workflow_name connected to subagent $custom_agent."