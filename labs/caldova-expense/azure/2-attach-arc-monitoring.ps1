<#
.SYNOPSIS
    Step 2 (Azure Side): Installs AzureMonitorWindowsAgent (AMAWindows) on the Azure Arc-enabled
    Windows Server (win-caldova-exp01) and associates the Caldova DCE + DCRs.

.DESCRIPTION
    Idempotent. Called automatically by 1-setup-azure-and-sre-agent.ps1 when the Arc machine is
    already connected, or run standalone right after you run 4-connect-azure-arc.ps1.

.EXAMPLE
    .\azure\2-attach-arc-monitoring.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8"
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = "",
    [string] $HybridResourceGroup = "rg-hybrid-connectivity",
    [string] $Location = "eastus2",
    [string] $MachineName = "win-caldova-exp01",
    [string] $DceName = "dce-caldova-central",
    [string] $WinDcrName = "dcr-caldova-win-telemetry",
    [string] $AppDcrName = "dcr-caldova-expense-applog"
)

$ErrorActionPreference = "Stop"

if ($SubscriptionId) {
    & az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription '$SubscriptionId'." }
}

& az extension add --name connectedmachine --upgrade --yes --only-show-errors | Out-Null

$machineJson = & az connectedmachine show -g $HybridResourceGroup -n $MachineName -o json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($machineJson -join ""))) {
    throw "Arc machine '$MachineName' was not found in '$HybridResourceGroup'. Run .\onprem\4-connect-azure-arc.ps1 first."
}
$machine = ($machineJson -join "`n") | ConvertFrom-Json
$machineId = $machine.id
Write-Host "Found Azure Arc machine: $($machine.name) (Status: $($machine.status))" -ForegroundColor Cyan

if ($machine.status -ne "Connected") {
    Write-Warning "Arc machine status is '$($machine.status)' (expected 'Connected'). Extension rollout will queue until the agent reconnects."
}

Write-Host "[1/2] Ensuring AzureMonitorWindowsAgent extension is installed on '$MachineName'..." -ForegroundColor Cyan
$existingExt = & az connectedmachine extension show `
    --machine-name $MachineName `
    --resource-group $HybridResourceGroup `
    --name AzureMonitorWindowsAgent -o json 2>$null

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($existingExt -join ""))) {
    $extObj = ($existingExt -join "`n") | ConvertFrom-Json
    Write-Host "  AzureMonitorWindowsAgent already present (provisioningState=$($extObj.provisioningState))." -ForegroundColor Green
}
else {
    & az connectedmachine extension create `
        --machine-name $MachineName `
        --resource-group $HybridResourceGroup `
        --location $Location `
        --name AzureMonitorWindowsAgent `
        --publisher Microsoft.Azure.Monitor `
        --type AzureMonitorWindowsAgent `
        --enable-auto-upgrade true | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install AzureMonitorWindowsAgent extension on '$MachineName'."
    }
    Write-Host "  AzureMonitorWindowsAgent installed." -ForegroundColor Green
}

Write-Host "[2/2] Associating DCE and Data Collection Rules with '$MachineName'..." -ForegroundColor Cyan
$subId = (& az account show --query id -o tsv).Trim()
$dceId    = "/subscriptions/$subId/resourceGroups/$HybridResourceGroup/providers/Microsoft.Insights/dataCollectionEndpoints/$DceName"
$winDcrId = ((& az resource show -g $HybridResourceGroup -n $WinDcrName --resource-type "Microsoft.Insights/dataCollectionRules" --query id -o tsv 2>$null) -join "").Trim()
$appDcrId = ((& az resource show -g $HybridResourceGroup -n $AppDcrName --resource-type "Microsoft.Insights/dataCollectionRules" --query id -o tsv 2>$null) -join "").Trim()

if (-not $winDcrId -or -not $appDcrId) {
    throw "Data Collection Rules '$WinDcrName' / '$AppDcrName' not found in '$HybridResourceGroup'. Run .\azure\1-setup-azure-and-sre-agent.ps1 first."
}

# configurationAccessEndpoint is the required reserved association name for DCE (needed for custom text log collection)
$assocBaseUrl = "https://management.azure.com$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations"
$dceBodyFile = [System.IO.Path]::GetTempFileName()
$winBodyFile = [System.IO.Path]::GetTempFileName()
$appBodyFile = [System.IO.Path]::GetTempFileName()

try {
    @{ properties = @{ dataCollectionEndpointId = $dceId } } | ConvertTo-Json -Compress | Set-Content -Path $dceBodyFile -NoNewline
    @{ properties = @{ dataCollectionRuleId = $winDcrId } } | ConvertTo-Json -Compress | Set-Content -Path $winBodyFile -NoNewline
    @{ properties = @{ dataCollectionRuleId = $appDcrId } } | ConvertTo-Json -Compress | Set-Content -Path $appBodyFile -NoNewline

    & az rest --method PUT --url "$assocBaseUrl/configurationAccessEndpoint?api-version=2022-06-01" --body "@$dceBodyFile" --headers "Content-Type=application/json" -o none
    if ($LASTEXITCODE -ne 0) { throw "Failed to associate DCE '$DceName' with '$MachineName'." }

    & az rest --method PUT --url "$assocBaseUrl/dcra-$MachineName-win?api-version=2022-06-01" --body "@$winBodyFile" --headers "Content-Type=application/json" -o none
    if ($LASTEXITCODE -ne 0) { throw "Failed to associate DCR '$WinDcrName' with '$MachineName'." }

    & az rest --method PUT --url "$assocBaseUrl/dcra-$MachineName-app?api-version=2022-06-01" --body "@$appBodyFile" --headers "Content-Type=application/json" -o none
    if ($LASTEXITCODE -ne 0) { throw "Failed to associate DCR '$AppDcrName' with '$MachineName'." }
}
finally {
    Remove-Item -Path $dceBodyFile, $winBodyFile, $appBodyFile -Force -ErrorAction SilentlyContinue
}

Write-Host "  Associated DCE ($DceName) + DCRs ($WinDcrName, $AppDcrName) with '$MachineName'." -ForegroundColor Green
Write-Host "`nAllow 5-10 minutes for initial Heartbeat, W3CIISLog, Event, Perf, and CaldovaExpenseApp_CL ingestion." -ForegroundColor Cyan
