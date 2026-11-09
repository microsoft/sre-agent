#!/usr/bin/env bash

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[!$' \t\r\n']*}"}"
  value="${value%"${value##*[!$' \t\r\n']}"}"
  printf '%s' "$value"
}

get_lab_value() {
  local name="$1"
  local optional="${2:-false}"
  local value

  if ! value="$(azd -C "$LAB_ROOT" env get-value "$name" 2>/dev/null)" ||
    [[ -z "$(trim_value "$value")" ]]; then
    if [[ "$optional" == "true" ]]; then
      return 0
    fi
    fail "Missing azd value $name. Complete the preceding lab deployment in this azd environment first."
  fi
  trim_value "$value"
}

invoke_lab_deployment() {
  local subscription_id="$1"
  local resource_group="$2"
  local deployment_name="$3"
  local template_file="$4"
  local parameters_json="$5"
  local parameter_file
  local result

  [[ -f "$template_file" ]] || fail 'The required lab template is missing. Add the template before deploying.'
  parameter_file="$(mktemp "${TMPDIR:-/tmp}/sre-agent-lab-parameters.XXXXXX")"

  if ! jq -n --argjson values "$parameters_json" '{
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
      contentVersion: "1.0.0.0",
      parameters: ($values | with_entries(.value = {value: .value}))
    }' >"$parameter_file"; then
    rm -f "$parameter_file"
    fail 'Unable to serialize the lab deployment parameters.'
  fi

  if ! result="$(az deployment group create \
    --subscription "$subscription_id" \
    --resource-group "$resource_group" \
    --name "$deployment_name" \
    --template-file "$template_file" \
    --parameters "@$parameter_file" \
    --mode Incremental \
    --only-show-errors \
    --output json 2>/dev/null)"; then
    rm -f "$parameter_file"
    fail "Lab deployment $deployment_name failed. Review the deployment in Azure; no automatic retry was attempted."
  fi
  rm -f "$parameter_file"

  jq -e '.properties.provisioningState == "Succeeded"' <<<"$result" >/dev/null 2>&1 ||
    fail "Lab deployment $deployment_name returned an invalid or unsuccessful response. Review it in Azure before continuing."
  jq -c '.properties.outputs' <<<"$result"
}
