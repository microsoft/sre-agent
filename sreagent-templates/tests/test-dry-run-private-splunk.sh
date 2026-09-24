#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

EXAMPLE="examples/private-splunk-mcp"
TEST_DIR="../.validation/private-splunk-tests"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/state"
trap 'rm -rf "$TEST_DIR"' EXIT

for script in "$EXAMPLE"/scripts/*.sh; do bash -n "$script"; done

az bicep build --file "$EXAMPLE/bicep/main.bicep" --outfile "$TEST_DIR/main.json" >/dev/null
grep -q '"same-region-network"' "$TEST_DIR/main.json"
grep -q '"cross-region-network"' "$TEST_DIR/main.json"
grep -q 'agentToSplunk' "$EXAMPLE/bicep/modules/cross-region-network.bicep"
! grep -q 'virtualNetworkPeerings' "$EXAMPLE/bicep/modules/same-region-network.bicep"
[[ "$(grep -c 'virtualNetworkLinks' "$EXAMPLE/bicep/modules/same-region-network.bicep")" -eq 1 ]]
[[ "$(grep -c 'virtualNetworkLinks' "$EXAMPLE/bicep/modules/cross-region-network.bicep")" -eq 2 ]]
grep -q "sameRegion!\\.outputs" "$EXAMPLE/bicep/main.bicep"
grep -q "crossRegion!\\.outputs" "$EXAMPLE/bicep/main.bicep"
grep -q '@allowed' "$EXAMPLE/bicep/main.bicep"
grep -q '^assert ' "$EXAMPLE/bicep/main.bicep"
[[ "$(grep -c 'privateDnsZoneName: foundation.outputs.privateDnsZoneName' "$EXAMPLE/bicep/main.bicep")" -eq 3 ]]
grep -q '"value": "same-region"' "$EXAMPLE/bicep/same-region.parameters.json.example"
! grep -q '"splunkLocation"\|"splunkVnetAddressPrefix"' "$EXAMPLE/bicep/same-region.parameters.json.example"
grep -q '"value": "cross-region"' "$EXAMPLE/bicep/cross-region.parameters.json.example"
grep -q '"splunkLocation"' "$EXAMPLE/bicep/cross-region.parameters.json.example"
grep -q 'output splunkVnetId string = labVnet.id' "$EXAMPLE/bicep/modules/same-region-network.bicep"

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir="$EXAMPLE/terraform" fmt -check -recursive
  terraform -chdir="$EXAMPLE/terraform" init -backend=false -input=false >/dev/null
  terraform -chdir="$EXAMPLE/terraform" validate
fi
grep -q 'count.*topology == "same-region"' "$EXAMPLE/terraform/main.tf"
grep -q 'count.*topology == "cross-region"' "$EXAMPLE/terraform/main.tf"
grep -q 'topology.*=.*"same-region"' "$EXAMPLE/terraform/same-region.tfvars.example"
! grep -q '^splunk_location\|^splunk_vnet_address_prefix' "$EXAMPLE/terraform/same-region.tfvars.example"
grep -q 'topology.*=.*"cross-region"' "$EXAMPLE/terraform/cross-region.tfvars.example"
grep -q '^splunk_location' "$EXAMPLE/terraform/cross-region.tfvars.example"
grep -q 'output "splunk_vnet_id".*azurerm_virtual_network.lab.id' "$EXAMPLE/terraform/modules/same-region-network/main.tf"
if grep -RE 'module\.(same_region_network|cross_region_network)\[0\]' "$EXAMPLE/terraform" --include='*.tf' | grep -vE 'var\.topology == "(same-region|cross-region)"'; then
  echo "Found unguarded conditional Terraform module access." >&2
  exit 1
fi

# Exercise shared validation directly, including all negative cases.
# shellcheck source=../examples/private-splunk-mcp/scripts/validation.sh
source "$EXAMPLE/scripts/validation.sh"
VALID_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButValidBase64ForOfflineValidation'
validate_deployment_inputs same-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.0.0/27 10.100.1.0/24 10.100.1.4 "$VALID_KEY"
validate_deployment_inputs cross-region eastus2 centralus 10.20.0.0/16 10.40.0.0/16 10.20.0.0/27 10.40.1.0/24 10.40.1.4 "$VALID_KEY"
expect_invalid() {
  if validate_deployment_inputs "$@" >/dev/null 2>&1; then
    echo "Expected validation failure: $*" >&2
    exit 1
  fi
}
expect_invalid unsupported eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.0.0/27 10.100.1.0/24 10.100.1.4 "$VALID_KEY"
expect_invalid cross-region eastus2 eastus2 10.20.0.0/16 10.40.0.0/16 10.20.0.0/27 10.40.1.0/24 10.40.1.4 "$VALID_KEY"
expect_invalid cross-region eastus2 centralus 10.20.0.0/16 10.20.0.0/16 10.20.0.0/27 10.20.1.0/24 10.20.1.4 "$VALID_KEY"
expect_invalid same-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.1.0/27 10.100.1.0/24 10.100.1.4 "$VALID_KEY"
expect_invalid same-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.101.0.0/27 10.100.1.0/24 10.100.1.4 "$VALID_KEY"
expect_invalid same-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.0.0/27 10.100.1.0/24 10.100.2.4 "$VALID_KEY"
expect_invalid same-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.0.0/27 10.100.1.0/24 10.100.1.3 "$VALID_KEY"
expect_invalid same-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.0.0/27 10.100.1.0/24 10.100.1.255 "$VALID_KEY"
expect_invalid same-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.0.0/27 10.100.1.0/24 10.100.1.4 invalid-key
expect_invalid cross-region eastus2 eastus2 10.100.0.0/16 10.100.0.0/16 10.100.0.0/27 10.100.1.0/24 10.100.1.4 "$VALID_KEY"

grep -q 'storage account keys list' "$EXAMPLE/scripts/configure-splunk.sh"
grep -q 'storage account keys list' "$EXAMPLE/scripts/Configure-Splunk.ps1"
! grep -Eq 'Storage Blob Data Contributor|role assignment create|--as-user' "$EXAMPLE/scripts/configure-splunk.sh" "$EXAMPLE/scripts/Configure-Splunk.ps1"
grep -q -- '--script "true"' "$EXAMPLE/scripts/mint-mcp-token.sh"
grep -q -- "'--script', 'true'" "$EXAMPLE/scripts/Mint-McpToken.ps1"
grep -q 'Treat it as compromised' "$EXAMPLE/scripts/mint-mcp-token.sh"
grep -q 'Treat it as compromised' "$EXAMPLE/scripts/Mint-McpToken.ps1"
grep -q 'splunkPasswordBase64' "$EXAMPLE/scripts/vm-bootstrap.sh"
grep -q 'packageUrlBase64' "$EXAMPLE/scripts/vm-bootstrap.sh"

if command -v jq >/dev/null 2>&1; then
cat >"$TEST_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="$*"
if [[ "$command" == "rest --method GET "* ]]; then
  if [[ "$command" == *"/providers/Microsoft.App/agents/"* ]]; then
    cat "$AZ_TEST_STATE/agent.json"
  else
    printf '%s\n' eastus2
  fi
  exit 0
fi
if [[ "$command" == "rest --method PATCH "* ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body" ]]; then
      cp "${2#@}" "$AZ_TEST_STATE/patch.json"
      jq -s '
        .[0] * .[1]
        | if .[1].properties.vnetConfiguration == null then del(.properties.vnetConfiguration) else . end
        | if .[1].properties.sandboxConfiguration == null then del(.properties.sandboxConfiguration) else . end
      ' "$AZ_TEST_STATE/agent.json" "${2#@}" >"$AZ_TEST_STATE/agent.next.json"
      mv "$AZ_TEST_STATE/agent.next.json" "$AZ_TEST_STATE/agent.json"
      exit 0
    fi
    shift
  done
fi
exit 13
EOF
chmod +x "$TEST_DIR/bin/az"
cat >"$TEST_DIR/state/agent.json" <<'EOF'
{"location":"East US 2","properties":{"vnetConfiguration":{"subnetResourceId":"/old/subnet","existingVnetSetting":"keep-vnet"},"sandboxConfiguration":{"packages":[{"name":"requests"}],"egress":{"allowedHosts":["existing.example"],"vnetConfiguration":{"existingDnsSetting":"keep-dns"}}}}}
EOF

AZ_TEST_STATE="$TEST_DIR/state" PATH="$TEST_DIR/bin:$PATH" "$EXAMPLE/scripts/capture-agent-state.sh" --subscription id --resource-group rg --agent-name agent --output "$TEST_DIR/original.json"
set +e
AZ_TEST_STATE="$TEST_DIR/state" PATH="$TEST_DIR/bin:$PATH" "$EXAMPLE/scripts/patch-agent.sh" --subscription id --resource-group rg --agent-name agent --subnet-id /new/subnet >"$TEST_DIR/refusal.out" 2>&1
refusal_status=$?
set -e
[[ "$refusal_status" -ne 0 ]]
AZ_TEST_STATE="$TEST_DIR/state" PATH="$TEST_DIR/bin:$PATH" "$EXAMPLE/scripts/patch-agent.sh" --subscription id --resource-group rg --agent-name agent --subnet-id /new/subnet --allow-subnet-reassignment
jq -e '.properties.vnetConfiguration.existingVnetSetting == "keep-vnet" and .properties.sandboxConfiguration.packages[0].name == "requests" and .properties.sandboxConfiguration.egress.mode == "AzureVNet" and .properties.sandboxConfiguration.egress.allowHttpMcpServerNetworkAccess == false and .properties.sandboxConfiguration.egress.vnetConfiguration.existingDnsSetting == "keep-dns"' "$TEST_DIR/state/patch.json" >/dev/null
AZ_TEST_STATE="$TEST_DIR/state" PATH="$TEST_DIR/bin:$PATH" "$EXAMPLE/scripts/restore-agent-state.sh" --subscription id --resource-group rg --agent-name agent --state-file "$TEST_DIR/original.json"

cat >"$TEST_DIR/state/agent.json" <<'EOF'
{"location":"East US 2","properties":{}}
EOF
AZ_TEST_STATE="$TEST_DIR/state" PATH="$TEST_DIR/bin:$PATH" "$EXAMPLE/scripts/capture-agent-state.sh" --subscription id --resource-group rg --agent-name agent --output "$TEST_DIR/original-empty.json"
jq -e '.properties.vnetConfiguration == null and .properties.sandboxConfiguration == null' "$TEST_DIR/original-empty.json" >/dev/null
AZ_TEST_STATE="$TEST_DIR/state" PATH="$TEST_DIR/bin:$PATH" "$EXAMPLE/scripts/patch-agent.sh" --subscription id --resource-group rg --agent-name agent --subnet-id /new/subnet
AZ_TEST_STATE="$TEST_DIR/state" PATH="$TEST_DIR/bin:$PATH" "$EXAMPLE/scripts/restore-agent-state.sh" --subscription id --resource-group rg --agent-name agent --state-file "$TEST_DIR/original-empty.json"
jq -e '(.properties | has("vnetConfiguration") | not) and (.properties | has("sandboxConfiguration") | not)' "$TEST_DIR/state/agent.json" >/dev/null
fi

if command -v pwsh >/dev/null 2>&1; then
  for script in "$EXAMPLE"/scripts/*.ps1; do
    PS_SCRIPT_PATH="$script" pwsh -NoProfile -Command '$errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($env:PS_SCRIPT_PATH, [ref]$null, [ref]$errors) > $null; if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }'
  done
  pwsh -NoProfile -File "$EXAMPLE/tests/Test-PowerShellRuntime.ps1"
fi

echo "private-splunk-mcp: PASS"
