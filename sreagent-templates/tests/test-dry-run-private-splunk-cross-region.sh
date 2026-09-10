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

if command -v terraform >/dev/null 2>&1 && [[ -f "$EXAMPLE/terraform/main.tf" ]]; then
  terraform -chdir="$EXAMPLE/terraform" fmt -check
  terraform -chdir="$EXAMPLE/terraform" init -backend=false -input=false >/dev/null
  terraform -chdir="$EXAMPLE/terraform" validate
fi

grep -q 'name.*=.*"DenyOtherVirtualNetworkInbound"' "$EXAMPLE/terraform/main.tf"
grep -q 'name.*=.*"DenyInternetInbound"' "$EXAMPLE/terraform/main.tf"
grep -q 'registration_enabled.*=.*false' "$EXAMPLE/terraform/main.tf"
grep -q 'service_delegation' "$EXAMPLE/terraform/main.tf"
if grep -q 'public_ip_address_id' "$EXAMPLE/terraform/main.tf"; then
  grep -q 'azurerm_nat_gateway_public_ip_association' "$EXAMPLE/terraform/main.tf"
fi

if command -v pwsh >/dev/null 2>&1; then
  for script in "$EXAMPLE"/scripts/*.ps1; do
    pwsh -NoProfile -Command '$errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$null, [ref]$errors) > $null; if ($errors.Count) { $errors | ForEach-Object { Write-Error $_ }; exit 1 }' "$script"
  done
fi

echo "private-splunk-cross-region: PASS"
