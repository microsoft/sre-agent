<#
.SYNOPSIS
    Induces Terraform drift by making manual changes to Azure resources outside of Terraform.
    After running this, `terraform plan` will show differences between config and reality.

.DESCRIPTION
    Makes 3 types of changes (drift) to show different severity levels:
    1. BENIGN   - Adds tags (harmless, cosmetic change — the #1 enterprise drift scenario)
    2. RISKY    - Downgrades TLS version from 1.2 to 1.0 (security regression)
    3. CRITICAL - Changes the App Service Plan SKU from B1 to S1 (cost/capacity impact)

.PARAMETER DriftType
    Which type of drift to create: Benign, Risky, Critical, or All (default: All)

.EXAMPLE
    .\induce-drift.ps1                    # Create all 3 types
    .\induce-drift.ps1 -DriftType Benign  # Just the tag change
    .\induce-drift.ps1 -DriftType Risky   # Just the TLS downgrade
#>

param(
    [string]$ResourceGroup = "iacdemo-rg",
    [string]$AppName = "iacdemo-webapp",
    [string]$PlanName = "iacdemo-plan",
    [ValidateSet("Benign", "Risky", "Critical", "All")]
    [string]$DriftType = "All"
)

$ErrorActionPreference = "Stop"

Write-Host "`n=== Terraform Drift Inducer ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroup"
Write-Host "App Service:    $AppName"
Write-Host "Drift Type:     $DriftType`n"

# ---------------------------------------------------------------
# 1. BENIGN DRIFT: Add tags that aren't in the Terraform config
# This is the #1 enterprise drift scenario: finance adds cost-center
# tags, devs add team labels, compliance adds audit tags — all
# through the Azure Portal, outside of Terraform.
# Terraform will show: ~ tags changed.
# ---------------------------------------------------------------
if ($DriftType -eq "Benign" -or $DriftType -eq "All") {
    Write-Host "[BENIGN] Adding unauthorized tags 'manual_update=true' and 'changed_by=portal_user'..." -ForegroundColor Green
    az webapp update `
        --resource-group $ResourceGroup `
        --name $AppName `
        --set tags.manual_update=true `
        --set tags.changed_by=portal_user `
        --output none
    Write-Host "[BENIGN] Done. These tags don't exist in the Terraform config, so Terraform will flag them.`n" -ForegroundColor Green
}

# ---------------------------------------------------------------
# 2. RISKY DRIFT: Downgrade TLS from 1.2 to 1.0
# This is a security regression — TLS 1.0 is deprecated and insecure.
# Terraform will show: ~ minimum_tls_version: "1.2" -> "1.0"
# ---------------------------------------------------------------
if ($DriftType -eq "Risky" -or $DriftType -eq "All") {
    Write-Host "[RISKY] Downgrading minimum TLS version from 1.2 to 1.0..." -ForegroundColor Yellow
    az webapp config set `
        --resource-group $ResourceGroup `
        --name $AppName `
        --min-tls-version 1.0 `
        --output none
    Write-Host "[RISKY] Done. TLS 1.0 is insecure — the agent should flag this as a security risk.`n" -ForegroundColor Yellow
}

# ---------------------------------------------------------------
# 3. CRITICAL DRIFT: Change SKU from B1 (Basic) to S1 (Standard)
# This changes cost ($13/mo -> $73/mo) and resource allocation.
# Terraform will show: ~ sku_name: "B1" -> "S1"
# ---------------------------------------------------------------
if ($DriftType -eq "Critical" -or $DriftType -eq "All") {
    Write-Host "[CRITICAL] Scaling App Service Plan from B1 to S1..." -ForegroundColor Red
    az appservice plan update `
        --resource-group $ResourceGroup `
        --name $PlanName `
        --sku S1 `
        --output none
    Write-Host "[CRITICAL] Done. This changes the server size and monthly cost.`n" -ForegroundColor Red
}

Write-Host "=== Drift induction complete ===" -ForegroundColor Cyan
Write-Host "`nWhat happened:"
Write-Host "  You just changed Azure resources directly (outside of Terraform)."
Write-Host "  Terraform does not know about these changes yet."
Write-Host "  When Terraform runs a plan, it compares its config to reality and shows the differences."
Write-Host "`nNext steps:"
Write-Host "  1. Run terraform plan in the terraform/ folder to see the drift"
Write-Host "  2. Or trigger the SRE Agent to investigate (Step 8 in the guide)"
Write-Host ""
