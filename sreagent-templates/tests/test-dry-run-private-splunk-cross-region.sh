#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

EXAMPLE="examples/private-splunk-mcp-cross-region"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for script in "$EXAMPLE"/scripts/*.sh; do
  bash -n "$script"
done

az bicep build --file "$EXAMPLE/bicep/main.bicep" --outfile "$TMP_DIR/main.json" >/dev/null

grep -q "Microsoft.App/environments" "$EXAMPLE/bicep/main.bicep"
grep -q "DenyOtherVirtualNetworkInbound" "$EXAMPLE/bicep/main.bicep"
grep -q "allowHttpMcpServerNetworkAccess.*false" "$EXAMPLE/scripts/patch-agent.sh"
grep -q "registrationEnabled: false" "$EXAMPLE/bicep/main.bicep"
grep -q "SPLUNKD_SSL_ENABLE=false" "$EXAMPLE/scripts/vm-bootstrap.sh"
grep -q "dependsOn:" "$EXAMPLE/bicep/main.bicep"
grep -q "agentToSplunk" "$EXAMPLE/bicep/main.bicep"

if command -v terraform >/dev/null 2>&1 && [[ -f "$EXAMPLE/terraform/main.tf" ]]; then
  terraform -chdir="$EXAMPLE/terraform" fmt -check
  terraform -chdir="$EXAMPLE/terraform" init -backend=false -input=false >/dev/null
  terraform -chdir="$EXAMPLE/terraform" validate
fi

grep -q 'name.*=.*"DenyOtherVirtualNetworkInbound"' "$EXAMPLE/terraform/main.tf"
grep -q 'name.*=.*"DenyInternetInbound"' "$EXAMPLE/terraform/main.tf"
grep -q 'registration_enabled.*=.*false' "$EXAMPLE/terraform/main.tf"
grep -q 'service_delegation' "$EXAMPLE/terraform/main.tf"
grep -q 'azurerm_virtual_network_peering.agent_to_splunk' "$EXAMPLE/terraform/main.tf"
if grep -q 'public_ip_address_id' "$EXAMPLE/terraform/main.tf"; then
  grep -q 'azurerm_nat_gateway_public_ip_association' "$EXAMPLE/terraform/main.tf"
fi

grep -q 'Get-OptionalProperty' "$EXAMPLE/scripts/Deploy.ps1"
grep -q 'Get-OptionalProperty' "$EXAMPLE/scripts/Patch-Agent.ps1"
grep -q 'storage account keys list' "$EXAMPLE/scripts/configure-splunk.sh"
grep -q 'storage account keys list' "$EXAMPLE/scripts/Configure-Splunk.ps1"
grep -q 'storage account delete' "$EXAMPLE/scripts/configure-splunk.sh"
grep -q 'storage account delete' "$EXAMPLE/scripts/Configure-Splunk.ps1"
grep -q 'base64 -d | bash -s' "$EXAMPLE/scripts/configure-splunk.sh"
grep -q 'base64 -d | bash -s' "$EXAMPLE/scripts/Configure-Splunk.ps1"
grep -q 'instanceView.exitCode' "$EXAMPLE/scripts/configure-splunk.sh"
grep -q 'instanceView.exitCode' "$EXAMPLE/scripts/Configure-Splunk.ps1"
grep -q 'base64 -d | bash -s' "$EXAMPLE/scripts/mint-mcp-token.sh"
grep -q 'base64 -d | bash -s' "$EXAMPLE/scripts/Mint-McpToken.ps1"
grep -q -- '--script "true"' "$EXAMPLE/scripts/mint-mcp-token.sh"
grep -q -- "'--script', 'true'" "$EXAMPLE/scripts/Mint-McpToken.ps1"
grep -q 'Treat it as compromised' "$EXAMPLE/scripts/mint-mcp-token.sh"
grep -q 'Treat it as compromised' "$EXAMPLE/scripts/Mint-McpToken.ps1"
grep -q 'splunkPasswordBase64' "$EXAMPLE/scripts/vm-bootstrap.sh"
grep -q 'packageUrlBase64' "$EXAMPLE/scripts/vm-bootstrap.sh"

awk '/^export DEBIAN_FRONTEND=/{exit} {print}' "$EXAMPLE/scripts/vm-bootstrap.sh" > "$TMP_DIR/bootstrap-parameters.sh"
cat >> "$TMP_DIR/bootstrap-parameters.sh" <<'EOF'
printf '%s\n' "$SPLUNK_PASSWORD" "$PACKAGE_URL" "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD" "$ENABLE_LAB_HTTP"
EOF
parameter_output="$(
  splunkPasswordBase64="$(printf '%s' 'P@ss word&value' | base64 | tr -d '\r\n')" \
  packageUrlBase64="$(printf '%s' 'https://example.test/package.tgz?sv=1&sig=a+b/c=' | base64 | tr -d '\r\n')" \
  registryServer="registry.example.test" \
  registryUsername="test-user" \
  registryPasswordBase64="$(printf '%s' 'Registry&password' | base64 | tr -d '\r\n')" \
  enableLabHttp="true" \
  bash "$TMP_DIR/bootstrap-parameters.sh"
)"
expected_parameter_output=$'P@ss word&value\nhttps://example.test/package.tgz?sv=1&sig=a+b/c=\nregistry.example.test\ntest-user\nRegistry&password\ntrue'
[[ "$parameter_output" == "$expected_parameter_output" ]]

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"
cat > "$TMP_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="$*"
if [[ "$command" == "rest --method GET "* ]]; then
  if [[ "$command" == *"/providers/Microsoft.App/agents/"* ]]; then
    printf '%s\n' '{"location":"East US 2","properties":{"vnetConfiguration":{"existingVnetSetting":"keep-vnet"},"sandboxConfiguration":{"packages":[{"name":"requests","packageManager":"pip"}],"egress":{"allowedHosts":["existing.example"],"allowedRegistries":["pypi"],"vnetConfiguration":{"existingDnsSetting":"keep-dns"}}}}}'
  else
    printf '%s\n' 'eastus2'
  fi
  exit 0
fi
if [[ "$command" == "rest --method PATCH "* ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body" ]]; then
      printf '%s' "$2" > "$AZ_TEST_STATE/patch.json"
      exit 0
    fi
    shift
  done
  exit 12
fi
if [[ "$command" == "vm show "* ]]; then
  printf '%s\n' 'eastus2'
  exit 0
fi
if [[ "$command" == "vm run-command create "* ]]; then
  if [[ "$command" == *"--script true"* ]]; then
    touch "$AZ_TEST_STATE/scrubbed"
    exit 0
  fi
  touch "$AZ_TEST_STATE/exists"
  if [[ "${AZ_CREATE_FAIL:-false}" == "true" ]]; then
    echo 'offline client create failure' >&2
    exit 42
  fi
  exit 0
fi
if [[ "$command" == "vm run-command delete "* ]]; then
  touch "$AZ_TEST_STATE/deleted"
  rm -f "$AZ_TEST_STATE/exists"
  exit 0
fi
if [[ "$command" == "vm run-command show "* ]]; then
  if [[ "$command" == *"--output none"* ]]; then
    if [[ -f "$AZ_TEST_STATE/exists" ]]; then
      exit 0
    fi
    echo 'ResourceNotFound: run command does not exist' >&2
    exit 1
  fi
  if [[ "$command" == *"instanceView.exitCode"* ]]; then
    printf '%s\n' '0'
  else
    printf '%s\n' 'offline-encrypted-token'
  fi
  exit 0
fi
exit 13
EOF
chmod +x "$TMP_DIR/bin/az"

AZ_TEST_STATE="$TMP_DIR/state" PATH="$TMP_DIR/bin:$PATH" \
  "$EXAMPLE/scripts/patch-agent.sh" \
  --subscription 00000000-0000-0000-0000-000000000000 \
  --resource-group offline-test-rg \
  --agent-name offline-test-agent \
  --subnet-id /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/offline-test-rg/providers/Microsoft.Network/virtualNetworks/offline-test-vnet/subnets/agent-subnet
jq -e '
  .properties.vnetConfiguration.existingVnetSetting == "keep-vnet"
  and .properties.sandboxConfiguration.packages[0].name == "requests"
  and .properties.sandboxConfiguration.egress.allowedHosts[0] == "existing.example"
  and .properties.sandboxConfiguration.egress.allowedRegistries[0] == "pypi"
  and .properties.sandboxConfiguration.egress.vnetConfiguration.existingDnsSetting == "keep-dns"
  and .properties.sandboxConfiguration.egress.mode == "AzureVNet"
  and .properties.sandboxConfiguration.egress.allowHttpMcpServerNetworkAccess == false
  and .properties.sandboxConfiguration.egress.vnetConfiguration.usePrivateDnsResolution == true
' "$TMP_DIR/state/patch.json" >/dev/null

set +e
printf '%s\n' 'offline-password' | AZ_TEST_STATE="$TMP_DIR/state" AZ_CREATE_FAIL=true PATH="$TMP_DIR/bin:$PATH" \
  "$EXAMPLE/scripts/mint-mcp-token.sh" --resource-group offline-test-rg --vm-name offline-test-vm --scheme http --days 1 \
  >"$TMP_DIR/mint.out" 2>&1
mint_status=$?
set -e
[[ "$mint_status" -eq 42 ]]
grep -q 'offline client create failure' "$TMP_DIR/mint.out"
[[ -f "$TMP_DIR/state/scrubbed" ]]
[[ -f "$TMP_DIR/state/deleted" ]]
[[ ! -f "$TMP_DIR/state/exists" ]]

if grep -q 'Storage Blob Data Contributor\|role assignment create\|--as-user' "$EXAMPLE/scripts/configure-splunk.sh" "$EXAMPLE/scripts/Configure-Splunk.ps1"; then
  echo "Package transfer must not depend on a self-granted data-plane role." >&2
  exit 1
fi
grep -q 'bicep/main.parameters.json' "$EXAMPLE/.gitignore"
grep -q 'terraform -chdir=terraform destroy -var-file=terraform.tfvars' "$EXAMPLE/README.md"
grep -q 'terraform -chdir=examples/private-splunk-mcp-cross-region/terraform destroy -var-file=terraform.tfvars' "$EXAMPLE/TESTING.md"

if command -v pwsh >/dev/null 2>&1; then
  for script in "$EXAMPLE"/scripts/*.ps1; do
    PS_SCRIPT_PATH="$script" pwsh -NoProfile -Command '$errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($env:PS_SCRIPT_PATH, [ref]$null, [ref]$errors) > $null; if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }'
  done
  pwsh -NoProfile -File "$EXAMPLE/tests/Test-PowerShellRuntime.ps1"
fi

echo "private-splunk-cross-region: PASS"
