#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
subscription_id=''
resource_id=''
check_only=false

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) subscription_id="${2:-}"; shift 2 ;;
    --resource-id) resource_id="${2:-}"; shift 2 ;;
    --check-only) check_only=true; shift ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

command -v az >/dev/null 2>&1 || fail 'Required command not found: az'
command -v curl >/dev/null 2>&1 || fail 'Required command not found: curl'
command -v jq >/dev/null 2>&1 || fail 'Required command not found: jq'
[[ "$subscription_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  fail 'Supply a valid subscription ID.'

normalized_id="$(printf '%s' "$resource_id" | tr '[:upper:]' '[:lower:]')"
normalized_subscription="$(printf '%s' "$subscription_id" | tr '[:upper:]' '[:lower:]')"
resource_pattern="^/subscriptions/${normalized_subscription}/resourcegroups/[a-z0-9_.()\-]+/providers/microsoft\.app/agents/[a-z0-9][a-z0-9-]*$"
[[ "$normalized_id" =~ $resource_pattern ]] ||
  fail 'ResourceId must be an SRE Agent ARM resource ID in the supplied subscription, without query, fragment or encoded path segments.'

arm_json="$(az rest --subscription "$subscription_id" --method get \
  --url "https://management.azure.com${resource_id}?api-version=2026-01-01" \
  --only-show-errors --output json 2>/dev/null)" ||
  fail 'Unable to read the agent from ARM. Check the lab subscription and access.'
arm_id="$(jq -er '.id | select(type == "string")' <<<"$arm_json" 2>/dev/null)" ||
  fail 'The ARM agent identity must match and actionConfiguration.mode must be Review. Review the agent in Azure manually.'
arm_mode="$(jq -er '.properties.actionConfiguration.mode | select(type == "string")' <<<"$arm_json" 2>/dev/null)" ||
  fail 'The ARM agent identity must match and actionConfiguration.mode must be Review. Review the agent in Azure manually.'
[[ "$(printf '%s' "$arm_id" | tr '[:upper:]' '[:lower:]')" == "$normalized_id" && "$arm_mode" == 'Review' ]] ||
  fail 'The ARM agent identity must match and actionConfiguration.mode must be Review. Review the agent in Azure manually.'

endpoint="$(jq -er '.properties.agentEndpoint | select(type == "string")' <<<"$arm_json" 2>/dev/null)" ||
  fail 'ARM must supply an HTTPS agent origin on port 443, without credentials, path, query or fragment.'
[[ "$endpoint" =~ ^https://[A-Za-z0-9.-]+(:443)?/?$ ]] ||
  fail 'ARM must supply an HTTPS agent origin on port 443, without credentials, path, query or fragment.'
endpoint="${endpoint%/}"
host="${endpoint#https://}"
host="${host%:443}"
[[ "$host" != 'localhost' && ! "$host" =~ ^[0-9.]+$ && "$host" == *.* ]] ||
  fail 'ARM must supply an HTTPS agent origin on port 443, without credentials, path, query or fragment.'

token="$(az account get-access-token --subscription "$subscription_id" --resource 'https://azuresre.dev' \
  --query accessToken --only-show-errors --output tsv 2>/dev/null)" ||
  fail 'Unable to obtain an SRE Agent token for the lab subscription. Sign in again and verify access.'
[[ -n "${token//[[:space:]]/}" ]] || fail 'Unable to obtain an SRE Agent token for the lab subscription. Sign in again and verify access.'

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sre-agent-permissions.XXXXXX")"
trap 'rm -rf "$work_dir"; token=""' EXIT

http_request() {
  local method="$1"
  local url="$2"
  local body_file="$3"
  local header_file="$4"
  local data_file="${5:-}"
  local etag="${6:-}"
  local args=(--silent --show-error --max-redirs 0 --request "$method" --dump-header "$header_file" --output "$body_file" --write-out '%{http_code}')
  [[ -n "$etag" ]] && args+=(--header "If-Match: $etag")
  [[ -n "$data_file" ]] && args+=(--header 'Content-Type: application/json' --data-binary "@$data_file")
  printf 'header = "Authorization: Bearer %s"\n' "$token" | curl --config - "${args[@]}" "$url"
}

feature_body="$work_dir/feature.json"
feature_headers="$work_dir/feature.headers"
feature_status="$(http_request GET "$endpoint/api/v1/Feature/status/enableV2AgentLoop" "$feature_body" "$feature_headers")" ||
  fail 'Unable to verify V2 permission concurrency support. No permissions were changed.'
[[ "$feature_status" == '200' ]] && jq -e '.enabled == true and (.enabled | type == "boolean")' "$feature_body" >/dev/null 2>&1 ||
  fail 'V2 agent loop and workspace tools must already be enabled. No permissions were changed.'

settings_body="$work_dir/settings.json"
settings_headers="$work_dir/settings.headers"
settings_status="$(http_request GET "$endpoint/api/v2/agent/settings/global" "$settings_body" "$settings_headers")" ||
  fail 'Unable to read global settings. Check access and endpoint availability; redirects are not permitted.'
[[ "$settings_status" == '200' ]] || fail 'Global settings GET did not return HTTP 200. No permissions were changed.'
jq -e '
  type == "object" and has("permissions") and
  (.permissions | type == "object" and
    ((keys - ["allow", "ask", "deny"]) | length == 0) and
    has("allow") and has("ask") and has("deny") and
    ([.allow, .ask, .deny] | all(type == "array" and all(.[]; type == "string" and length > 0))))
' "$settings_body" >/dev/null 2>&1 ||
  fail 'Unrecognized permission settings. Review the policy manually; no permissions were changed.'

desired="$script_dir/permissions.json"
legacy="$work_dir/legacy.json"
cat >"$legacy" <<'JSON'
{"permissions":{"allow":["GetAzCliHelp","ReadFile","GrepSearch","FetchGithubIssues"],"ask":["*"],"deny":[]}}
JSON

policy_signature() {
  jq -c '[.permissions.allow, .permissions.ask, .permissions.deny] | map(map(ascii_downcase) | unique | sort)' "$1"
}

current_signature="$(policy_signature "$settings_body")"
desired_signature="$(policy_signature "$desired")"
legacy_signature="$(policy_signature "$legacy")"
if [[ "$current_signature" == "$desired_signature" ]]; then
  printf '%s\n' 'Global permissions already match the lab policy; no changes made. ARM Review mode verified.'
  exit 0
fi

is_empty="$(jq -r '([.permissions.allow, .permissions.ask, .permissions.deny] | add | length) == 0' "$settings_body")"
is_legacy=false
[[ "$current_signature" == "$legacy_signature" ]] && is_legacy=true
if [[ "$is_empty" != 'true' && "$is_legacy" != 'true' ]]; then
  fail 'Existing nonempty global permissions differ from the lab policy. Review them manually against permissions.json; no changes were made.'
fi
[[ "$check_only" != 'true' ]] ||
  fail 'Global permissions are empty. Complete Part 2 permission setup separately before enabling incidents; this check made no changes.'

etag_lines="$(awk 'tolower($1) == "etag:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print }' "$settings_headers")"
etag_count="$(printf '%s\n' "$etag_lines" | awk 'NF { count++ } END { print count+0 }')"
strong_etag_pattern='^"[^"[:cntrl:][:space:]]+"$'
if [[ "$etag_count" -eq 0 ]]; then
  [[ "$is_legacy" != 'true' ]] || fail 'The legacy lab policy was detected, but global settings returned no ETag. No permissions were changed.'
  etag='*'
elif [[ "$etag_count" -eq 1 && "$etag_lines" =~ $strong_etag_pattern ]]; then
  etag="$etag_lines"
else
  fail 'Global settings returned an invalid strong ETag. No permissions were changed.'
fi

update_body="$work_dir/update.json"
update_headers="$work_dir/update.headers"
update_status="$(http_request PUT "$endpoint/api/v2/agent/settings/global" "$update_body" "$update_headers" "$desired" "$etag")" ||
  fail 'Permission update failed. Review the current policy manually before rerunning; no retry was attempted.'
if [[ "$update_status" == '412' ]]; then
  fail 'Permissions changed concurrently (HTTP 412). No retry or bypass was attempted. Review the current policy manually.'
fi
[[ "$update_status" == '200' ]] || fail 'Permission update did not return HTTP 200. Review the current policy manually.'
printf '%s\n' 'Installed the lab global policy; Azure mutation tools are denied and incident reads/follow-ups are pre-authorized.'
