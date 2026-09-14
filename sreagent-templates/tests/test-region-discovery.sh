#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_AZ_CALLS:?}"
case "$1 $2" in
  "account show")
    printf '%s\n' "default-subscription"
    ;;
  "provider show")
    [[ -z "${FAKE_PROVIDER_FAIL:-}" ]] || exit 1
    printf '%s\n' '["East US 2","Poland Central","North Central US (Stage)"]'
    ;;
  "rest --method")
    printf '%s\n' '[{"name":"eastus2","displayName":"East US 2"},{"name":"polandcentral","displayName":"Poland Central"}]'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/az"

export PATH="$FAKE_BIN:$PATH"
export FAKE_AZ_CALLS="$TMP/az-calls"
source "$ROOT/bin/region-utils.sh"

[[ "$(resolve_azure_subscription "")" == "default-subscription" ]]
[[ "$(resolve_azure_subscription "explicit-subscription")" == "explicit-subscription" ]]

regions=$(get_sre_agent_regions "target-subscription")
[[ "$regions" == $'eastus2\npolandcentral' ]]
grep -Fq "provider show --subscription target-subscription" "$FAKE_AZ_CALLS"
grep -Fq "subscriptions/target-subscription/locations" "$FAKE_AZ_CALLS"

validate_sre_agent_region "target-subscription" "polandcentral"
if output=$(validate_sre_agent_region "target-subscription" "westus3" 2>&1); then
  echo "FAIL: unavailable region passed validation" >&2
  exit 1
fi
[[ "$output" == *"westus3"* ]]
[[ "$output" == *"learn.microsoft.com/azure/sre-agent/supported-regions"* ]]

fallback_regions=$(FAKE_PROVIDER_FAIL=1 get_sre_agent_regions_or_fallback "target-subscription" 2>/dev/null)
[[ "$(wc -l <<<"$fallback_regions" | tr -d ' ')" == "20" ]]
grep -Fxq "southcentralus" <<<"$fallback_regions"

output_dir="$TMP/generated-agent"
"$ROOT/bin/new-agent.sh" \
  --recipe minimal \
  --subscription target-subscription \
  --set agentName=region-test \
  --set resourceGroup=region-test-rg \
  --set location=polandcentral \
  --set targetRGs=target-rg \
  --non-interactive \
  --no-telemetry \
  --output "$output_dir" >/dev/null
[[ "$(jq -r '.identity.subscription' "$output_dir/agent.json")" == "target-subscription" ]]
[[ "$(jq -r '.identity.location' "$output_dir/agent.json")" == "polandcentral" ]]

echo "PASS: region discovery uses the selected subscription"