#!/usr/bin/env bash

SRE_AGENT_REGIONS_DOC_URL="https://learn.microsoft.com/azure/sre-agent/supported-regions"
SRE_AGENT_REGIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/supported-regions.json"

resolve_azure_subscription() {
  local subscription="${1:-}"
  if [[ -n "$subscription" ]]; then
    printf '%s\n' "$subscription"
    return 0
  fi

  subscription=$(az account show --query id -o tsv 2>/dev/null) || true
  if [[ -z "$subscription" ]]; then
    echo "Error: no Azure subscription selected. Run 'az login' and 'az account set --subscription <id>', or pass --subscription." >&2
    return 1
  fi
  printf '%s\n' "$subscription"
}

get_sre_agent_regions() {
  local subscription="$1"
  local advertised_locations azure_locations

  advertised_locations=$(az provider show \
    --subscription "$subscription" \
    --namespace Microsoft.App \
    --query "resourceTypes[?resourceType=='agents'].locations | [0]" \
    -o json 2>/dev/null) || true

  if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$advertised_locations"; then
    echo "Error: Azure SRE Agent returned no available regions for subscription '$subscription'." >&2
    echo "See $SRE_AGENT_REGIONS_DOC_URL" >&2
    return 1
  fi

  azure_locations=$(az rest \
    --method GET \
    --url "https://management.azure.com/subscriptions/${subscription}/locations?api-version=2022-12-01" \
    --query "value[].{name:name,displayName:displayName}" \
    -o json 2>/dev/null) || true

  if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$azure_locations"; then
    echo "Error: unable to resolve Azure region names for subscription '$subscription'." >&2
    echo "See $SRE_AGENT_REGIONS_DOC_URL" >&2
    return 1
  fi

  jq -nr \
    --argjson advertised "$advertised_locations" \
    --argjson locations "$azure_locations" \
    '$locations
      | map(select(.displayName as $displayName | $advertised | index($displayName)))
      | map(.name)
      | unique[]'
}

get_sre_agent_regions_or_fallback() {
  local subscription="$1"
  local regions

  if regions=$(get_sre_agent_regions "$subscription"); then
    printf '%s\n' "$regions"
    return 0
  fi

  echo "Warning: using the checked-in region list because subscription discovery was unavailable." >&2
  echo "See $SRE_AGENT_REGIONS_DOC_URL" >&2
  jq -r '.[]' "$SRE_AGENT_REGIONS_FILE"
}

validate_sre_agent_region() {
  local subscription="$1"
  local region="$2"
  local regions

  regions=$(get_sre_agent_regions "$subscription") || return 1
  if grep -Fxq "$region" <<<"$regions"; then
    return 0
  fi

  echo "Error: region '$region' is not available for Azure SRE Agent in subscription '$subscription'." >&2
  echo "Available regions: $(paste -s -d, - <<<"$regions")" >&2
  echo "See $SRE_AGENT_REGIONS_DOC_URL" >&2
  return 1
}