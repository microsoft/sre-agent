<#
.SYNOPSIS
    All-in-one on-premises orchestrator for your Windows Server 2022/2025 VM.
    Runs IIS/.NET/SQL host setup, initializes CaldovaExpenseDb, deploys CaldovaExpense.zip,
    and optionally connects Azure Arc if -SubscriptionId is provided.

.EXAMPLE
    .\onprem\setup-onprem-all.ps1 -ZipPath .\CaldovaExpense.zip -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" -UseDeviceCode
#>
[CmdletBinding()]
param(
    [string] $ZipPath = "",
    [int]    $Port = 8080,
    [string] $SubscriptionId = "",
    [string] $ResourceGroup = "rg-hybrid-connectivity",
    [string] $Location = "eastus2",
    [string] $MachineName = "win-caldova-exp01",
    [string] $TenantId = "",
    [string] $ServicePrincipalId = "",
    [string] $ServicePrincipalSecret = "",
    [switch] $UseDeviceCode,
    [switch] $AllowPrivateSubnetPort8080
)

$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "1-setup-windows-host.ps1") -AllowPrivateSubnetPort8080:$AllowPrivateSubnetPort8080
& (Join-Path $PSScriptRoot "2-setup-database.ps1")
& (Join-Path $PSScriptRoot "3-deploy-caldova-expense.ps1") -ZipPath $ZipPath -Port $Port

if ($SubscriptionId) {
    $arcParams = @{
        SubscriptionId = $SubscriptionId
        ResourceGroup  = $ResourceGroup
        Location       = $Location
        MachineName    = $MachineName
        UseDeviceCode  = $UseDeviceCode
    }
    if ($TenantId)               { $arcParams["TenantId"] = $TenantId }
    if ($ServicePrincipalId)     { $arcParams["ServicePrincipalId"] = $ServicePrincipalId }
    if ($ServicePrincipalSecret) { $arcParams["ServicePrincipalSecret"] = $ServicePrincipalSecret }

    & (Join-Path $PSScriptRoot "4-connect-azure-arc.ps1") @arcParams
}
else {
    Write-Host "`nSkipped Step 4 (Azure Arc) because -SubscriptionId was not supplied. Run .\onprem\4-connect-azure-arc.ps1 when ready." -ForegroundColor Yellow
}
