#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
role_name="SREAgentRole"
generated_variables_file="$script_dir/guided.auto.tfvars.json"
plan_file="$script_dir/tfplan"
agent_api_version="2025-05-01-preview"
identity_resource_id=""
allowed_permissions=""
skip_approval="false"
resource_id_provided=false
permissions_provided=false
skip_approval_provided=false

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

policy_description() {
  case "$1" in
    SREAgentReadOnlyAccess)
      printf 'Inspect AWS resources and telemetry, read application data and secrets, and decrypt data.'
      ;;
    SREAgentWriteAccess)
      printf 'Open workload sessions and database connections; restart, stop, scale, or recover resources.'
      ;;
  esac
}

while (($# > 0)); do
  option="$1"
  case "$option" in
    --resource-id|--allowed-permissions|--skip-approval)
      (($# >= 2)) && [[ "$2" != --* ]] || fail "Missing value for $option."
      value="$2"
      shift 2
      ;;
    --resource-id=*|--allowed-permissions=*|--skip-approval=*)
      value="${option#*=}"
      option="${option%%=*}"
      shift
      ;;
    --help|-h)
      printf 'Usage: ./setup.sh [--resource-id <MI-or-Agent-ARM-ID>] [--allowed-permissions read-only|read-write] [--skip-approval true|false]\n'
      printf 'read-only selects SREAgentReadOnlyAccess; read-write selects both access policies.\n'
      printf 'skip-approval defaults to false (y/n confirmation). Set true to apply without confirmation. Missing inputs are still prompted.\n'
      exit 0
      ;;
    *)
      fail "Unknown argument: $1. Use --help for usage."
      ;;
  esac
  case "$option" in
    --resource-id)
      [[ "$resource_id_provided" == false ]] || fail "Duplicate --resource-id argument."
      identity_resource_id="$value"
      resource_id_provided=true
      ;;
    --allowed-permissions)
      [[ "$permissions_provided" == false ]] || fail "Duplicate --allowed-permissions argument."
      allowed_permissions="$value"
      permissions_provided=true
      ;;
    --skip-approval)
      [[ "$skip_approval_provided" == false ]] || fail "Duplicate --skip-approval argument."
      skip_approval="$value"
      skip_approval_provided=true
      ;;
  esac
done
skip_approval="${skip_approval,,}"
[[ "$skip_approval" == true || "$skip_approval" == false ]] \
  || fail "Invalid skip-approval value. Choose true or false."

printf '\nSRE Agent AWS connector setup\n'
printf 'This script reads the Azure managed identity and lets Terraform configure AWS.\n\n'
if [[ "$resource_id_provided" == false ]]; then
  read -r -p 'Enter the full ARM resource ID of the user-assigned managed identity or SRE Agent: ' identity_resource_id \
    || fail "An ARM resource ID is required."
fi
identity_resource_id="$(trim "$identity_resource_id")"
subscription_pattern='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
resource_id_pattern="^/subscriptions/$subscription_pattern/resourcegroups/[^/[:space:]?#]+/providers/(microsoft\\.managedidentity/userassignedidentities|microsoft\\.app/agents)/[^/[:space:]?#]+$"
[[ "${identity_resource_id,,}" =~ $resource_id_pattern ]] \
  || fail "Invalid ARM resource ID. Expected /subscriptions/<subscription-guid>/resourceGroups/<group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name> or Microsoft.App/agents/<name>."
if [[ "${BASH_REMATCH[1]}" == "microsoft.managedidentity/userassignedidentities" ]]; then
  identity_type="UserAssigned"
else
  identity_type="SystemAssigned"
fi

if [[ "$permissions_provided" == false ]]; then
  printf '\nAvailable permission levels:\n'
  printf '  read-only - SREAgentReadOnlyAccess: %s\n' "$(policy_description SREAgentReadOnlyAccess)"
  printf '  read-write - SREAgentReadOnlyAccess + SREAgentWriteAccess: %s\n' "$(policy_description SREAgentWriteAccess)"
  printf 'Example: --allowed-permissions read-only (or read-write)\n'
  read -r -p 'Enter allowed permissions: read-only or read-write: ' allowed_permissions \
    || fail "An allowed-permissions value is required. Choose read-only or read-write."
fi
allowed_permissions="$(trim "$allowed_permissions")"
allowed_permissions="${allowed_permissions,,}"
[[ "$allowed_permissions" == read-only || "$allowed_permissions" == read-write ]] \
  || fail "Invalid allowed-permissions value. Choose read-only or read-write."
policy_names=(SREAgentReadOnlyAccess)
if [[ "$allowed_permissions" == read-write ]]; then
  policy_names+=(SREAgentWriteAccess)
fi

decode_rfc3986() {
  local encoded="$1"
  printf '%b' "${encoded//%/\\x}"
}

terraform_supported() {
  local version
  local major
  local minor
  local patch
  local suffix

  version="$(terraform version 2>/dev/null | head -n 1)" || return 1
  [[ "$version" =~ ^Terraform\ v([0-9]+)\.([0-9]+)\.([0-9]+)([-+][^[:space:]]+)?$ ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  suffix="${BASH_REMATCH[4]:-}"

  [[ "$suffix" != -* ]] || return 1
  ((major > 1)) ||
    ((major == 1 && minor > 7)) ||
    ((major == 1 && minor == 7 && patch >= 0))
}

aws_cli_supported() {
  local version

  version="$(aws --version 2>&1)" || return 1
  [[ "$version" =~ aws-cli/([0-9]+)\. ]] || return 1
  ((BASH_REMATCH[1] >= 2))
}

for command in az aws terraform jq; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done
terraform_supported || fail "Terraform 1.7 or later is required."
aws_cli_supported || fail "AWS CLI v2 is required."

cd "$script_dir"

policy_files=()
for name in "${policy_names[@]}"; do
  policy_path="$script_dir/$name.json"
  [[ -f "$policy_path" ]] || fail "Policy JSON file not found: $policy_path"
  jq -e '
    type == "object" and .Version == "2012-10-17"
    and (.Statement | if type == "object" then [.] else . end
      | type == "array" and length > 0
      and all(.[]; type == "object" and (.Effect == "Allow" or .Effect == "Deny")))
  ' "$policy_path" >/dev/null \
    || fail "Policy '$policy_path' must be valid JSON with Version 2012-10-17 and nonempty Statement objects."
  policy_files+=("$policy_path")
done
workload_policies="$(
  jq -cs --arg names "${policy_names[*]}" '
    ($names | split(" ")) as $names |
    to_entries | map({key: $names[.key], value: .value}) | from_entries
  ' "${policy_files[@]}"
)" || fail "Unable to load the selected policy files."
jq -e '
  [.[].Statement | if type == "array" then .[] else . end | select(has("Sid")) | .Sid] |
  length == (unique | length)
' >/dev/null <<<"$workload_policies" || fail "Duplicate policy statement Sid in the selected policies."
jq -e '[.[] | tojson | length] | add <= 10240' >/dev/null <<<"$workload_policies" \
  || fail "The workload policies exceed the 10,240-character aggregate role inline-policy limit."
policy_source="$(IFS=', '; printf '%s' "${policy_names[*]}")"
printf '\nAllowed permissions: %s\n' "$allowed_permissions"
printf 'Selected policies to apply:\n'
for name in "${policy_names[@]}"; do
  printf '  %s - %s\n' "$name" "$(policy_description "$name")"
done
printf 'WARNING: Selected permissions are shared by every identity trusted by SREAgentRole. ReadOnlyAccess exposes data and credentials; WriteAccess permits workload changes and can cause outages.\n'

case "$identity_type" in
  UserAssigned)
    identity_json="$(
      az identity show \
        --ids "$identity_resource_id" \
        --query '{name:name,tenantId:tenantId,clientId:clientId,principalId:principalId}' \
        --output json
    )" || fail "Unable to read the managed identity. Run az login and verify access."
    ;;
  SystemAssigned)
    agent_identity_json="$(
      az resource show \
        --ids "$identity_resource_id" \
        --api-version "$agent_api_version" \
        --query '{name:name,identityType:identity.type,tenantId:identity.tenantId,principalId:identity.principalId}' \
        --output json
    )" || fail "Unable to read the SRE Agent resource. Run az login and verify access."

    jq -e '
      (.identityType // "" | split(",") | map(gsub("^\\s+|\\s+$"; "")) | index("SystemAssigned") != null)
      and (.tenantId | type == "string" and length > 0)
      and (.principalId | type == "string" and length > 0)
    ' >/dev/null <<<"$agent_identity_json" \
      || fail "The selected SRE Agent does not have a ready system-assigned managed identity."

    principal_id="$(jq -er '.principalId' <<<"$agent_identity_json")"
    client_id="$(
      az ad sp show \
        --id "$principal_id" \
        --query appId \
        --output tsv
    )" || fail "Unable to resolve the system identity Client ID from Entra. Verify directory read access and allow time for identity propagation."
    [[ -n "$client_id" ]] \
      || fail "The system identity service principal did not return a Client ID."

    identity_json="$(
      jq -n \
        --arg name "$(jq -er '.name' <<<"$agent_identity_json")" \
        --arg tenant_id "$(jq -er '.tenantId' <<<"$agent_identity_json")" \
        --arg client_id "$client_id" \
        --arg principal_id "$principal_id" \
        '{
          name: $name,
          tenantId: $tenant_id,
          clientId: $client_id,
          principalId: $principal_id
        }'
    )"
    ;;
esac

identity_name="$(jq -er '.name' <<<"$identity_json")"
tenant_id="$(jq -er '.tenantId' <<<"$identity_json")"
client_id="$(jq -er '.clientId' <<<"$identity_json")"
principal_id="$(jq -er '.principalId' <<<"$identity_json")"

caller_json="$(AWS_PAGER="" aws sts get-caller-identity --no-cli-pager --output json)" \
  || fail "Unable to read the AWS caller identity. Sign in to AWS and try again."
aws_account_id="$(jq -er '.Account | select(test("^[0-9]{12}$"))' <<<"$caller_json")" \
  || fail "AWS returned an invalid account ID."
caller_arn="$(jq -er '.Arn' <<<"$caller_json")"
[[ "$caller_arn" =~ ^arn:([^:]+): ]] || fail "AWS returned an invalid caller ARN."
aws_partition="${BASH_REMATCH[1]}"
[[ "$aws_partition" == "aws" ]] \
  || fail "This setup supports the commercial AWS partition only. Active partition: $aws_partition"

issuer="https://login.microsoftonline.com/$tenant_id/v2.0"
provider_path="login.microsoftonline.com/$tenant_id/v2.0"
provider_arn="arn:$aws_partition:iam::$aws_account_id:oidc-provider/$provider_path"

provider_exists=false
provider_json='{}'
provider_error_file="$(mktemp)"
if provider_json="$(
  AWS_PAGER="" aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$provider_arn" \
    --no-cli-pager \
    --output json 2>"$provider_error_file"
)"; then
  provider_exists=true
elif grep -q '(NoSuchEntity)' "$provider_error_file"; then
  provider_json='{}'
else
  cat "$provider_error_file" >&2
  rm -f "$provider_error_file"
  fail "Unable to inspect the OIDC provider."
fi
rm -f "$provider_error_file"

existing_provider_audiences="$(jq -c '[.ClientIDList[]?]' <<<"$provider_json")" \
  || fail "AWS returned invalid OIDC provider JSON."
audience_exists=false
if jq -e --arg client_id "$client_id" \
  '.ClientIDList // [] | index($client_id) != null' >/dev/null <<<"$provider_json"; then
  audience_exists=true
fi
existing_audience_count="$(jq -r '.ClientIDList // [] | length' <<<"$provider_json")"
if [[ "$audience_exists" == false && "$existing_audience_count" -ge 100 ]]; then
  fail "The existing IAM OIDC provider already has 100 audiences. Remove an unused audience before adding this managed identity."
fi

role_exists=false
role_json='{}'
role_error_file="$(mktemp)"
if role_json="$(
  AWS_PAGER="" aws iam get-role \
    --role-name "$role_name" \
    --no-cli-pager \
    --output json 2>"$role_error_file"
)"; then
  role_exists=true
elif grep -q '(NoSuchEntity)' "$role_error_file"; then
  role_json='{}'
else
  cat "$role_error_file" >&2
  rm -f "$role_error_file"
  fail "Unable to inspect $role_name."
fi
rm -f "$role_error_file"

role_path="$(jq -r '.Role.Path // "/"' <<<"$role_json")"
role_description="$(
  jq -r '
    if .Role == null then
      "Assumed by an Azure managed identity through Microsoft Entra OIDC federation."
    else
      .Role.Description // ""
    end
  ' \
    <<<"$role_json"
)"
max_session_duration="$(jq -r '.Role.MaxSessionDuration // 3600' <<<"$role_json")"
role_arn="$(jq -r --arg fallback "arn:$aws_partition:iam::$aws_account_id:role/$role_name" '.Role.Arn // $fallback' <<<"$role_json")"

role_trust_policy='{}'
if [[ "$role_exists" == true ]]; then
  role_trust_policy_type="$(
    jq -r '.Role.AssumeRolePolicyDocument | type' <<<"$role_json"
  )"
  if [[ "$role_trust_policy_type" == "object" ]]; then
    role_trust_policy="$(
      jq -c '.Role.AssumeRolePolicyDocument' <<<"$role_json"
    )"
  elif [[ "$role_trust_policy_type" == "string" ]]; then
    encoded_role_trust_policy="$(
      jq -r '.Role.AssumeRolePolicyDocument' <<<"$role_json"
    )"
    role_trust_policy="$(decode_rfc3986 "$encoded_role_trust_policy")"
    jq -e 'type == "object"' >/dev/null <<<"$role_trust_policy" \
      || fail "AWS returned an invalid encoded IAM role trust policy."
  else
    fail "The existing IAM role does not contain a valid trust policy."
  fi
fi

trust_sid="TrustManagedIdentity$(tr '[:upper:]' '[:lower:]' <<<"${client_id//-/}")"
audience_condition_key="$provider_path:aud"
subject_condition_key="$provider_path:sub"
existing_role_trust_statements="$(
  jq -c \
    --arg sid "$trust_sid" \
    --arg audience_key "$audience_condition_key" \
    --arg subject_key "$subject_condition_key" \
    --arg client_id "$client_id" \
    --arg principal_id "$principal_id" \
    '
    def exactly_matches($expected):
      if type == "array" then
        length == 1 and .[0] == $expected
      else
        . == $expected
      end;

    [
      (
        .Statement
        | if . == null then [] elif type == "array" then . else [.] end
      )[]
      | select(
          (.Sid // "") != $sid
          and (
            (
              ((.Condition.StringEquals[$audience_key] // null) | exactly_matches($client_id))
              and ((.Condition.StringEquals[$subject_key] // null) | exactly_matches($principal_id))
            )
            | not
          )
        )
    ]' <<<"$role_trust_policy"
)"

additional_audiences='[]'
if [[ -f "$generated_variables_file" ]]; then
  jq -e . "$generated_variables_file" >/dev/null \
    || fail "The existing guided.auto.tfvars.json file is not valid JSON."
  additional_audiences="$(
    jq -c '.additional_oidc_provider_audiences // []' "$generated_variables_file"
  )"
  if [[ "$role_exists" == false ]]; then
    role_path="$(jq -r '.role_path // "/"' "$generated_variables_file")"
    role_description="$(
      jq -r '.role_description // "Assumed by an Azure managed identity through Microsoft Entra OIDC federation."' \
        "$generated_variables_file"
    )"
    max_session_duration="$(jq -r '.max_session_duration // 3600' "$generated_variables_file")"
  fi
fi
if [[ "$provider_exists" == true ]]; then
  additional_audiences="$(
    jq -c --arg client_id "$client_id" \
      '[.ClientIDList[]? | select(. != $client_id)] | unique | sort' \
      <<<"$provider_json"
  )"
fi

jq -n \
  --arg identity_type "$identity_type" \
  --arg resource_id "$identity_resource_id" \
  --arg name "$identity_name" \
  --arg tenant_id "$tenant_id" \
  --arg client_id "$client_id" \
  --arg principal_id "$principal_id" \
  --arg role_name "$role_name" \
  --arg role_path "$role_path" \
  --arg role_description "$role_description" \
  --argjson max_session_duration "$max_session_duration" \
  --argjson existing_role_trust_statements "$existing_role_trust_statements" \
  --argjson additional_audiences "$additional_audiences" \
  --argjson workload_policies "$workload_policies" \
  '{
    managed_identity: {
      type: $identity_type,
      resource_id: $resource_id,
      name: $name,
      tenant_id: $tenant_id,
      client_id: $client_id,
      principal_id: $principal_id
    },
    role_name: $role_name,
    role_path: $role_path,
    role_description: $role_description,
    max_session_duration: $max_session_duration,
    existing_role_trust_statements: $existing_role_trust_statements,
    additional_oidc_provider_audiences: $additional_audiences,
    workload_policies: $workload_policies
  }' >"$generated_variables_file"
chmod 600 "$generated_variables_file"

printf '\nDiscovered Azure identity\n'
printf '  Identity type:    %s\n' "$identity_type"
printf '  Managed identity: %s\n' "$identity_name"
printf '  Tenant ID:        %s\n' "$tenant_id"
printf '  Client ID:        %s\n' "$client_id"
printf '  Principal ID:     %s\n' "$principal_id"
printf '  AWS account ID:   %s\n' "$aws_account_id"
printf '  OIDC provider:    %s\n' "$provider_arn"

printf '\nTerraform will manage:\n'
if [[ "$provider_exists" == true ]]; then
  printf '  Microsoft Entra OIDC provider: existing; import into this Terraform state\n'
else
  printf '  Microsoft Entra OIDC provider: create\n'
fi
if [[ "$audience_exists" == true ]]; then
  printf '  Managed identity audience: already present\n'
else
  printf '  Managed identity audience: add\n'
fi
  if [[ "$role_exists" == true ]]; then
    printf '  IAM role: %s (existing; preserve current trust and add this identity)\n' "$role_name"
  else
    printf '  IAM role: %s (create)\n' "$role_name"
  fi
printf '  AWS MCP OAuth managed policy attachment\n'
printf '  Inline policies: %s\n' "$policy_source"

if ! terraform_output="$(terraform init -input=false -no-color 2>&1)"; then
  printf '%s\n' "$terraform_output" >&2
  fail "terraform init failed."
fi

if ! state_output="$(terraform state list 2>&1)"; then
  if [[ "$state_output" == *"No state file was found"* ]]; then
    state_output=""
  else
    printf '%s\n' "$state_output" >&2
    fail "Unable to read Terraform state."
  fi
fi

if grep -Fxq 'aws_iam_openid_connect_provider.entra' <<<"$state_output"; then
  if ! provider_state="$(
    terraform state show -no-color aws_iam_openid_connect_provider.entra 2>&1
  )"; then
    printf '%s\n' "$provider_state" >&2
    fail "Unable to inspect the Terraform OIDC provider state binding."
  fi
  state_provider_arn="$(
    sed -nE 's/^[[:space:]]*arn[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
      <<<"$provider_state" |
      head -n 1
  )"
  [[ -n "$state_provider_arn" ]] \
    || fail "Terraform state for aws_iam_openid_connect_provider.entra does not contain an ARN."
  [[ "$state_provider_arn" == "$provider_arn" ]] \
    || fail "Terraform state is bound to $state_provider_arn, not $provider_arn. Use the authoritative state for the selected AWS account and Entra tenant."
elif [[ "$provider_exists" == true ]]; then
    printf 'Importing the existing OIDC provider into the local Terraform state...\n'
    if ! terraform_output="$(
      terraform import -input=false -no-color \
        aws_iam_openid_connect_provider.entra "$provider_arn" 2>&1
    )"; then
      printf '%s\n' "$terraform_output" >&2
      fail "Unable to import the existing OIDC provider."
    fi
fi

if [[ "$role_exists" == true ]] &&
  grep -Fxq 'aws_iam_role.entra' <<<"$state_output"; then
  if ! role_state="$(terraform state show -no-color aws_iam_role.entra 2>&1)"; then
    printf '%s\n' "$role_state" >&2
    fail "Unable to inspect the Terraform IAM role state binding."
  fi
  state_role_arn="$(
    sed -nE 's/^[[:space:]]*arn[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
      <<<"$role_state" |
      head -n 1
  )"
  [[ -n "$state_role_arn" ]] \
    || fail "Terraform state for aws_iam_role.entra does not contain an ARN."
  [[ "$state_role_arn" == "$role_arn" ]] \
    || fail "Terraform state is bound to $state_role_arn, not $role_arn. Use the authoritative state for the selected AWS account and role."
elif [[ "$role_exists" == true ]]; then
  printf 'Importing the existing %s role into the local Terraform state...\n' "$role_name"
  if ! terraform_output="$(
    terraform import -input=false -no-color aws_iam_role.entra "$role_name" 2>&1
  )"; then
    printf '%s\n' "$terraform_output" >&2
    fail "Unable to import the existing $role_name role."
  fi
fi

if ! terraform_output="$(
  terraform plan -input=false -no-color -out="$plan_file" 2>&1
)"; then
  printf '%s\n' "$terraform_output" >&2
  fail "terraform plan failed. Review the Terraform output and the local state before rerunning."
fi

printf '\n'
if [[ "$skip_approval" == false ]]; then
  confirmation=""
  read -r -p 'Proceed with these AWS changes? [y/n]: ' confirmation || true
  confirmation="$(trim "$confirmation")"
  if [[ "${confirmation,,}" != "y" ]]; then
    printf 'No AWS changes were applied.\n'
    rm -f "$plan_file"
    exit 0
  fi
else
  printf 'skip-approval=true; applying without confirmation.\n'
fi

terraform apply -input=false -auto-approve "$plan_file"
rm -f "$plan_file"

printf '\nAWS setup completed.\n'
printf 'Role: %s\n\n' "$role_name"
printf 'To review the SRE Agent inline policies, open IAM > Roles > %s > Permissions in the AWS Console: %s.\n' "$role_name" "$policy_source"
