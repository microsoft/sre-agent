<#
.SYNOPSIS
    Creates a least-privilege Service Principal scoped strictly to 'Azure Connected Machine Onboarding'
    on rg-hybrid-connectivity so you can run 4-connect-azure-arc.ps1 without needing
    interactive Azure subscription permissions.

.EXAMPLE
    .\azure\create-arc-onboarding-sp.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $HybridResourceGroup = "rg-hybrid-connectivity",
    [string] $Location = "eastus2",
    [string] $MachineName = "win-caldova-exp01",
    [string] $SpDisplayName = "sp-caldova-arc-onboarding"
)

$ErrorActionPreference = "Stop"

& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription '$SubscriptionId'." }

& az group create -n $HybridResourceGroup -l $Location -o none
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$HybridResourceGroup"

# Built-in role: Azure Connected Machine Onboarding
$onboardingRoleId = "b64e21ea-ac4e-4cdf-9dc9-5b892992bee7"

Write-Host "Creating/updating Service Principal '$SpDisplayName' scoped to $rgScope..." -ForegroundColor Cyan
$spRaw = & az ad sp create-for-rbac `
    --name $SpDisplayName `
    --role $onboardingRoleId `
    --scopes $rgScope `
    -o json
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create onboarding Service Principal. Verify Entra application creation permissions or use -UseDeviceCode."
}

$sp = ($spRaw -join "`n") | ConvertFrom-Json

Write-Host "`nSecurely transfer and run the following command on '$MachineName':" -ForegroundColor Green
Write-Host @"

.\onprem\4-connect-azure-arc.ps1 ``
  -SubscriptionId "$SubscriptionId" ``
  -ResourceGroup "$HybridResourceGroup" ``
  -Location "$Location" ``
  -MachineName "$MachineName" ``
  -TenantId "$($sp.tenant)" ``
  -ServicePrincipalId "$($sp.appId)" ``
  -ServicePrincipalSecret "$($sp.password)"

"@ -ForegroundColor White
