#!/usr/bin/env bash
set -euo pipefail

setup_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pool_id="sre-agent-pool"
provider_id="sre-agent-provider"
role_id="SREAgentRole"
audience="59f0a04a-b322-4310-adc9-39ac41e9631e"
uuid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$1" >&2
}

run_json() {
  local output
  output="$("$@")" || fail "$1 ${2:-} failed; see command diagnostics."
  jq -cs 'if length == 1 then .[0] else error("Expected one JSON result.") end' <<<"$output"
}

assert_active_resource() {
  if ! jq -e '.state != "DELETED" and .deleted != true' >/dev/null <<<"$1"; then
    fail "$2 is soft-deleted. Restore it through your approved process before rerunning."
  fi
  if ! jq -e '.disabled != true and .stage != "DISABLED"' >/dev/null <<<"$1"; then
    fail "$2 is disabled. Review and enable it through your approved process before rerunning."
  fi
}

get_provider_condition() {
  jq -cn --argjson provider "$1" --arg tenant "$2" --arg object "$3" \
    --arg audience "$audience" --arg uuid "$uuid_pattern" '
    def trim: gsub("^\\s+|\\s+$"; "");
    def allowlist($ids):
      $ids | map("assertion.oid == \u0027" + . + "\u0027") | join(" || ");
    ($object | ascii_downcase) as $id |
    if $provider == null then
      {condition: allowlist([$id]), reset: false}
    elif ($provider | has("oidc") | not) then
      error("The existing fixed-name provider is not OIDC; it cannot be adopted.")
    else
      $provider.attributeMapping as $mapping |
      (($mapping | type) == "object" and ($mapping | length) == 1 and
        ($mapping["google.subject"] // "" |
          test("^\\s*assertion\\s*\\.\\s*tid\\s*\\+\\s*([\u0027\"])::\\1\\s*\\+\\s*assertion\\s*\\.\\s*oid\\s*$"))) as $mapping_matches |
      ($provider.oidc.issuerUri == ("https://login.microsoftonline.com/" + ($tenant | ascii_downcase) + "/v2.0") and
        $provider.oidc.allowedAudiences == [$audience] and $mapping_matches and
        ($provider.oidc.jwksJson // "") == "") as $compatible |
      ($provider.attributeCondition // "" | trim) as $condition |
      if ($compatible | not) or $condition == "" then
        {condition: allowlist([$id]), reset: true}
      else
        # Older jq versions require grouping the full concatenation before binding.
        ("(?:\u0027" + $uuid + "\u0027|\"" + $uuid + "\")") as $quoted_id_pattern |
        ("assertion\\.oid\\s*==\\s*" + $quoted_id_pattern) as $comparison_pattern |
        ("^(?<prefix>\\([\\s\\S]+\\)\\r?\\n\\|\\|\\s*)?(?<comparisons>" +
          $comparison_pattern + "(?:\\s*\\|\\|\\s*" + $comparison_pattern + ")*)$") as $or_pattern |
        "^(?<prefix>\\([\\s\\S]+\\)\\r?\\n\\|\\|\\s*)?assertion\\.oid\\s+in\\s+\\[(?<values>[^\\]]*)\\]$" as $list_pattern |
        ([$condition | capture($or_pattern)][0]) as $comparisons |
        ([$condition | capture($list_pattern)][0]) as $managed |
        (if $comparisons != null then
          {prefix: ($comparisons.prefix // ""),
           ids: ([$comparisons.comparisons | scan($uuid)] | map(ascii_downcase))}
        elif $managed != null and
          ($managed.values | split(",") | all(trim | test("^" + $quoted_id_pattern + "$"))) then
          {prefix: ($managed.prefix // ""),
           ids: ($managed.values | split(",") | map(trim | .[1:-1] | ascii_downcase))}
        else
          # A newline terminates trailing CEL comments before appending trust.
          {prefix: ("(" + $condition + "\n)\n|| "), ids: []}
        end) as $existing |
        ($existing.prefix + allowlist(($existing.ids + [$id]) | unique)) as $merged |
        if ($merged | length) > 4096 then
          error("The merged provider condition exceeds the GCP 4096-character limit.")
        else
          {condition: $merged, reset: false}
        end
      end
    end'
}

append_import() {
  local quoted_id
  quoted_id="$(jq -cn --arg id "$2" '$id')"
  printf -v imports '%simport {\n  to = %s\n  id = %s\n}\n' "$imports" "$1" "$quoted_id"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$workspace_created" == true ]]; then
    if ! (
      cd "$run_directory" &&
        terraform workspace select default &&
        terraform workspace delete -force "$workspace"
    ); then
      warn "Workspace cleanup failed. Local state is retained at $run_directory."
      exit 1
    fi
  fi
  if ! rm -rf -- "$run_directory"; then
    warn "Temporary file cleanup failed. Inspect $run_directory."
    exit 1
  fi
  exit "$status"
}

main() {
  local resource_id="" access_mode="" skip_approval="false" scope="project" organization_id=""
  local option value command version major minor
  while (($#)); do
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
      printf '%s\n' \
        'Usage: ./setup.sh --resource-id <UAMI_ARM_ID> --allowed-permissions <read-only|read-write>' \
        '                  [--skip-approval <true|false>]' \
        '                  [--assignment-scope <project|organization>] [--organization-id <ID>]'
      return
    fi
    if [[ "$1" == --*=* ]]; then
      option="${1%%=*}"
      value="${1#*=}"
      shift
    else
      option="$1"
      [[ $# -ge 2 && "$2" != --* ]] || fail "Missing value for $option."
      value="$2"
      shift 2
    fi
    case "$option" in
      --resource-id) resource_id="$value" ;;
      --allowed-permissions) access_mode="$value" ;;
      --skip-approval) skip_approval="$value" ;;
      --assignment-scope) scope="$value" ;;
      --organization-id) organization_id="$value" ;;
      *) fail "Unknown parameter: $option" ;;
    esac
  done

  shopt -s nocasematch
  [[ "$resource_id" =~ ^/subscriptions/$uuid_pattern/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$ ]] \
    || fail "--resource-id must be a full Azure user-assigned managed identity resource ID."
  shopt -u nocasematch
  [[ "$access_mode" == "read-only" || "$access_mode" == "read-write" ]] \
    || fail "--allowed-permissions must be read-only or read-write."
  [[ "$skip_approval" == "true" || "$skip_approval" == "false" ]] \
    || fail "--skip-approval must be true or false."
  [[ "$scope" == "project" || "$scope" == "organization" ]] \
    || fail "--assignment-scope must be project or organization."
  if [[ "$scope" == "organization" ]]; then
    [[ "$organization_id" =~ ^[0-9]+$ ]] || fail "--organization-id is required for organization scope and must be numeric."
  else
    [[ -z "$organization_id" ]] || fail "--organization-id can only be supplied with organization scope."
  fi
  for command in az gcloud terraform jq; do
    command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
  done
  version="$(run_json terraform version -json)"
  version="$(jq -er '.terraform_version' <<<"$version")"
  [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(\+[^[:space:]]+)?$ ]] \
    || fail "A stable Terraform 1.7 or later release is required."
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  ((10#$major > 1 || (10#$major == 1 && 10#$minor >= 7))) \
    || fail "A stable Terraform 1.7 or later release is required."

  local accounts account configured_project project project_id project_number project_flag services enabled_services required
  accounts="$(run_json gcloud auth list --filter=status:ACTIVE --format=json)"
  [[ "$(jq 'length' <<<"$accounts")" == 1 ]] || fail "No unique active gcloud account. Run gcloud auth login."
  configured_project="$(gcloud config get project)" || fail "Unable to read the configured gcloud project."
  [[ -n "$configured_project" && "$configured_project" != "(unset)" ]] \
    || fail "No GCP project configured. Run gcloud config set project <PROJECT_ID>."
  project="$(run_json gcloud projects describe "$configured_project" --format=json --quiet)"
  project_id="$(jq -er '.projectId' <<<"$project")"
  project_number="$(jq -er '.projectNumber' <<<"$project")"
  [[ "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ && "$project_number" =~ ^[0-9]+$ ]] \
    || fail "gcloud returned an invalid project ID or project number."
  project_flag="--project=$project_id"
  services="$(run_json gcloud services list --enabled "$project_flag" --format=json --quiet)"
  enabled_services="$(jq -c '[.[].config.name]' <<<"$services")"
  for required in serviceusage.googleapis.com iam.googleapis.com; do
    jq -e --arg service "$required" 'index($service) != null' >/dev/null <<<"$enabled_services" \
      || fail "Enable $required in $project_id through your approved process before setup."
  done
  account="$(jq -er '.[0].account' <<<"$accounts")"
  printf '\nSRE Agent GCP connector setup\nAccount: %s\nProject: %s (%s)\n' \
    "$account" "$project_id" "$project_number"

  local identity tenant_id object_id scope_flag scope_parent scope_id policy_kind
  identity="$(run_json az identity show --ids "$resource_id" \
    --query '{tenantId:tenantId,principalId:principalId}' --output json)"
  tenant_id="$(jq -er '.tenantId | ascii_downcase' <<<"$identity")"
  object_id="$(jq -er '.principalId | ascii_downcase' <<<"$identity")"
  [[ "$tenant_id" =~ ^$uuid_pattern$ && "$object_id" =~ ^$uuid_pattern$ ]] \
    || fail "Azure did not return a valid tenant ID and principal/object ID."
  scope_flag="$project_flag"
  scope_parent="projects/$project_id"
  scope_id="$project_id"
  policy_kind="projects"
  if [[ "$scope" == "organization" ]]; then
    scope_flag="--organization=$organization_id"
    scope_parent="organizations/$organization_id"
    scope_id="$organization_id"
    policy_kind="organizations"
    warn "Organization-level access is inherited by descendant resources."
  fi

  local pool_name provider_name pool_import_id role_name principal pools pool providers provider roles role details
  local imports="" existing_permissions="[]" trust condition policy has_assignment service
  pool_name="projects/$project_number/locations/global/workloadIdentityPools/$pool_id"
  provider_name="$pool_name/providers/$provider_id"
  # Import stores this project segment in the replacement-only project field.
  pool_import_id="projects/$project_id/locations/global/workloadIdentityPools/$pool_id"
  role_name="$scope_parent/roles/$role_id"
  principal="principal://iam.googleapis.com/$pool_name/subject/$tenant_id::$object_id"
  pools="$(run_json gcloud iam workload-identity-pools list --location=global \
    --show-deleted "$project_flag" --format=json --quiet)"
  pool="$(jq -c --arg name "$pool_name" 'map(select(.name == $name)) | .[0] // null' <<<"$pools")"
  provider="null"
  if [[ "$pool" != "null" ]]; then
    assert_active_resource "$pool" SREAgentPool
    append_import google_iam_workload_identity_pool.sre_agent "$pool_import_id"
    providers="$(run_json gcloud iam workload-identity-pools providers list --location=global \
      "--workload-identity-pool=$pool_id" --show-deleted "$project_flag" --format=json --quiet)"
    provider="$(jq -c --arg name "$provider_name" 'map(select(.name == $name)) | .[0] // null' <<<"$providers")"
    if [[ "$provider" != "null" ]]; then
      assert_active_resource "$provider" SREAgentProvider
      provider="$(run_json gcloud iam workload-identity-pools providers describe "$provider_id" \
        --location=global "--workload-identity-pool=$pool_id" "$project_flag" --format=json --quiet)"
      assert_active_resource "$provider" SREAgentProvider
      append_import google_iam_workload_identity_pool_provider.azure "$pool_import_id/providers/$provider_id"
    fi
  fi
  trust="$(get_provider_condition "$provider" "$tenant_id" "$object_id")"
  condition="$(jq -er '.condition' <<<"$trust")"
  if [[ "$(jq -r '.reset' <<<"$trust")" == true ]]; then
    warn "The existing provider configuration is incompatible or unrestricted. Terraform will correct its issuer/audience/mapping and trust ONLY the selected identity. Existing identities may lose access. Review the plan carefully."
  fi

  roles="$(run_json gcloud iam roles list "$scope_flag" --show-deleted --format=json --quiet)"
  role="$(jq -c --arg name "$role_name" 'map(select(.name == $name)) | .[0] // null' <<<"$roles")"
  if [[ "$role" != "null" ]]; then
    assert_active_resource "$role" "$role_id"
    details="$(run_json gcloud iam roles describe "$role_id" "$scope_flag" --format=json --quiet)"
    assert_active_resource "$details" "$role_id"
    jq -e '.includedPermissions | type == "array"' >/dev/null <<<"$details" \
      || fail "The existing role has no includedPermissions array; refusing to replace unknown permissions."
    existing_permissions="$(jq -c '.includedPermissions' <<<"$details")"
    append_import "google_${scope}_iam_custom_role.sre_agent_role[0]" "$role_name"
  fi
  policy="$(run_json gcloud "$policy_kind" get-iam-policy "$scope_id" --format=json --quiet)"
  has_assignment="$(jq -r --arg role "$role_name" --arg member "$principal" '
    any(.bindings[]?; .role == $role and (has("condition") | not) and
      (.members | index($member) != null))' <<<"$policy")"
  if [[ "$has_assignment" == true ]]; then
    append_import "google_${scope}_iam_member.sre_agent_role_assignment[0]" "$scope_id $role_name $principal"
  fi
  for service in iam.googleapis.com cloudresourcemanager.googleapis.com iamcredentials.googleapis.com sts.googleapis.com; do
    if jq -e --arg service "$service" 'index($service) != null' >/dev/null <<<"$enabled_services"; then
      append_import "google_project_service.required[\"$service\"]" "$project_id/$service"
    fi
  done

  printf 'Azure tenant: %s\nManaged identity object ID: %s\nProvider: %s\nRole: %s\nPermissions to add: %s; preserve %s existing permissions.\n' \
    "$tenant_id" "$object_id" "$provider_name" "$role_name" "$access_mode" "$(jq length <<<"$existing_permissions")"
  warn "All SREAgentRole assignees share merged permissions. Read-only does not downgrade an existing read-write role."
  warn "Run setups sequentially. Do not concurrently manage these resources from another Terraform state. The temporary workspace is deleted WITHOUT destroying GCP resources."

  umask 077
  run_directory="$(mktemp -d "${TMPDIR:-/tmp}/sre-agent-gcp-XXXXXXXX")"
  workspace="${run_directory##*/}"
  workspace_created=false
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cp "$setup_root"/*.tf "$run_directory/"
  jq -n --arg project_id "$project_id" --arg project_number "$project_number" \
    --arg tenant "$tenant_id" --arg object "$object_id" --arg mode "$access_mode" \
    --arg scope "$scope" --arg organization "$organization_id" --arg condition "$condition" \
    --argjson permissions "$existing_permissions" '{
      project_id: $project_id, project_number: $project_number,
      azure_tenant_id: $tenant, uami_object_id: $object, access_mode: $mode,
      assignment_scope: $scope, organization_id: $organization,
      attribute_condition: $condition, existing_role_permissions: $permissions
    }' >"$run_directory/guided.auto.tfvars.json"
  printf '%s' "$imports" >"$run_directory/imports.tf"
  unset TF_WORKSPACE TF_DATA_DIR GOOGLE_OAUTH_ACCESS_TOKEN GOOGLE_CREDENTIALS \
    GOOGLE_CLOUD_KEYFILE_JSON GCLOUD_KEYFILE_JSON GOOGLE_IMPERSONATE_SERVICE_ACCOUNT
  GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token --quiet)" || fail "Unable to obtain the gcloud access token."
  [[ "$GOOGLE_OAUTH_ACCESS_TOKEN" =~ [^[:space:]] ]] || fail "gcloud returned an empty access token. Run gcloud auth login."
  export GOOGLE_OAUTH_ACCESS_TOKEN
  cd "$run_directory"
  terraform init -input=false -no-color
  terraform workspace new "$workspace"
  workspace_created=true
  if [[ "$skip_approval" == true ]]; then
    warn "Approval is explicitly skipped, including any provider trust reset or shared-role permission expansion."
    terraform apply -no-color -input=false -auto-approve=true \
      || fail "Terraform apply failed. No destroy is run; inspect the output before rerunning."
  else
    terraform apply -no-color -input=true -auto-approve=false \
      || fail "Terraform apply was cancelled or failed. No destroy is run; inspect the output before rerunning."
  fi
  local outputs provider_output role_output principal_output
  outputs="$(run_json terraform output -json)"
  provider_output="$(jq -er '.workload_identity_provider.value' <<<"$outputs")" \
    || fail "Terraform output is missing workload_identity_provider."
  role_output="$(jq -er '.role_name.value' <<<"$outputs")" || fail "Terraform output is missing role_name."
  principal_output="$(jq -er '.principal_id.value' <<<"$outputs")" || fail "Terraform output is missing principal_id."
  printf '\nCopy this Workload Identity Provider into the SRE Agent GCP connector:\n%s\nRole: %s\nPrincipal: %s\n' \
    "$provider_output" "$role_output" "$principal_output"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap 'printf "Error: setup failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR
  main "$@"
fi
