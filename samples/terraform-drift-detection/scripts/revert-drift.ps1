<#
.SYNOPSIS
    Reverts all drift back to Terraform-defined state (undoes induce-drift.ps1).

.EXAMPLE
    .\revert-drift.ps1
#>

param(
    [string]$ResourceGroup = "iacdemo-rg",
    [string]$AppName = "iacdemo-webapp",
    [string]$PlanName = "iacdemo-plan"
)

$ErrorActionPreference = "Stop"

Write-Host "`n=== Reverting Terraform Drift ===" -ForegroundColor Cyan

# Remove unauthorized tags
Write-Host "[REVERT] Removing unauthorized tags..." -ForegroundColor Green
az webapp update `
    --resource-group $ResourceGroup `
    --name $AppName `
    --remove tags.manual_update `
    --output none 2>$null
az webapp update `
    --resource-group $ResourceGroup `
    --name $AppName `
    --remove tags.changed_by `
    --output none 2>$null
Write-Host "[REVERT] Tags removed.`n" -ForegroundColor Green

# Restore TLS 1.2
Write-Host "[REVERT] Restoring minimum TLS to 1.2..." -ForegroundColor Yellow
az webapp config set `
    --resource-group $ResourceGroup `
    --name $AppName `
    --min-tls-version 1.2 `
    --output none
Write-Host "[REVERT] TLS restored.`n" -ForegroundColor Yellow

# Restore B1 SKU
Write-Host "[REVERT] Restoring App Service Plan to B1..." -ForegroundColor Red
az appservice plan update `
    --resource-group $ResourceGroup `
    --name $PlanName `
    --sku B1 `
    --output none
Write-Host "[REVERT] SKU restored.`n" -ForegroundColor Red

Write-Host "=== All drift reverted ===" -ForegroundColor Cyan
Write-Host "Run 'terraform plan' to verify everything is clean (should show 'No changes').`n"
