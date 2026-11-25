<#
.SYNOPSIS
    Cleans up Azure SRE Agent and/or Caldova Expense monitoring resources.
    Supports -WhatIf and -Confirm for safe execution.

.EXAMPLE
    .\azure\cleanup-azure.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" -WhatIf
    .\azure\cleanup-azure.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8" -DeleteHybridResourceGroup
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string] $SubscriptionId = "",
    [string] $AgentResourceGroup = "rg-caldova-sre-agent",
    [string] $HybridResourceGroup = "rg-hybrid-connectivity",
    [string] $MachineName = "win-caldova-exp01",
    [switch] $DeleteHybridResourceGroup
)

$ErrorActionPreference = "Stop"

if ($SubscriptionId) {
    & az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription '$SubscriptionId'." }
}
$subId = (& az account show --query id -o tsv).Trim()

if ($PSCmdlet.ShouldProcess($AgentResourceGroup, "Delete SRE Agent resource group '$AgentResourceGroup'")) {
    Write-Host "Deleting SRE Agent resource group '$AgentResourceGroup'..." -ForegroundColor Yellow
    & az group delete -n $AgentResourceGroup --yes --no-wait
}

if ($DeleteHybridResourceGroup) {
    if ($PSCmdlet.ShouldProcess($HybridResourceGroup, "Delete entire hybrid resource group '$HybridResourceGroup'")) {
        Write-Host "Deleting hybrid resource group '$HybridResourceGroup'..." -ForegroundColor Yellow
        & az group delete -n $HybridResourceGroup --yes --no-wait
    }
}
else {
    # Remove only the Caldova DCR associations, DCRs, and DCE while preserving rg-hybrid-connectivity
    $machineId = "/subscriptions/$subId/resourceGroups/$HybridResourceGroup/providers/Microsoft.HybridCompute/machines/$MachineName"
    foreach ($assoc in @("dcra-$MachineName-win", "dcra-$MachineName-app", "configurationAccessEndpoint")) {
        if ($PSCmdlet.ShouldProcess("$MachineName/$assoc", "Delete DCR association")) {
            & az rest --method DELETE --url "https://management.azure.com$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$assoc`?api-version=2022-06-01" -o none 2>$null
        }
    }
    foreach ($dcr in @("dcr-caldova-win-telemetry", "dcr-caldova-expense-applog")) {
        if ($PSCmdlet.ShouldProcess("$HybridResourceGroup/$dcr", "Delete Data Collection Rule")) {
            & az rest --method DELETE --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$HybridResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$dcr`?api-version=2022-06-01" -o none 2>$null
        }
    }
    if ($PSCmdlet.ShouldProcess("$HybridResourceGroup/dce-caldova-central", "Delete Data Collection Endpoint")) {
        & az rest --method DELETE --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$HybridResourceGroup/providers/Microsoft.Insights/dataCollectionEndpoints/dce-caldova-central?api-version=2022-06-01" -o none 2>$null
    }
    Write-Host "Removed Caldova DCR associations, DCRs, and DCE (preserved '$HybridResourceGroup' and 'law-caldova-central'). Pass -DeleteHybridResourceGroup to delete the entire RG." -ForegroundColor Green
}
