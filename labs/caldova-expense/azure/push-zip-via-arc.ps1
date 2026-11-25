<#
.SYNOPSIS
    Remotely deploys an updated CaldovaExpense.zip to the on-premises Windows Server (win-caldova-exp01)
    over Azure Arc's outbound 443 channel using 'az connectedmachine run-command create' — zero CI/CD
    agents and zero inbound firewall ports required!

.DESCRIPTION
    1. Builds CaldovaExpense.zip locally (unless -ZipPath is passed to an existing ZIP).
    2. Creates/reuses a private staging Storage Account in rg-hybrid-connectivity and uploads the ZIP.
    3. Generates a short-lived (30-minute) read-only Blob SAS URI.
    4. Runs 'az connectedmachine run-command create' on win-caldova-exp01 to stop CaldovaExpensePool,
       extract the new ZIP into C:\inetpub\caldova-expense, restart the AppPool, and verify /api/health.

.EXAMPLE
    .\azure\push-zip-via-arc.ps1 -SubscriptionId "66a7fcba-dac3-46d8-b509-202f305618c8"
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = "",
    [string] $HybridResourceGroup = "rg-hybrid-connectivity",
    [string] $Location = "eastus2",
    [string] $MachineName = "win-caldova-exp01",
    [string] $ZipPath = "",
    [string] $StagingStorageAccount = "",
    [int]    $Port = 8080
)

$ErrorActionPreference = "Stop"

if ($SubscriptionId) {
    & az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription '$SubscriptionId'." }
}
$subId = (& az account show --query id -o tsv).Trim()

& az extension add --name connectedmachine --upgrade --yes --only-show-errors | Out-Null

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ZipPath) {
    $ZipPath = Join-Path $repoRoot "CaldovaExpense.zip"
    Write-Host "[1/4] Building fresh CaldovaExpense.zip..." -ForegroundColor Cyan
    & (Join-Path $repoRoot "scripts\build-package.ps1") -OutputZip $ZipPath
}
elseif (-not (Test-Path $ZipPath)) {
    throw "ZIP file not found at '$ZipPath'."
}

if (-not $StagingStorageAccount) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$subId|$HybridResourceGroup|caldovastage"))
        $hash  = (([System.BitConverter]::ToString($bytes)) -replace '-', '').ToLowerInvariant().Substring(0, 12)
    }
    finally { $sha.Dispose() }
    $StagingStorageAccount = "stcaldova$hash"
}

Write-Host "[2/4] Staging package in private blob container ($StagingStorageAccount)..." -ForegroundColor Cyan
$stExists = & az storage account show -g $HybridResourceGroup -n $StagingStorageAccount -o json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($stExists -join ""))) {
    & az storage account create `
        -g $HybridResourceGroup `
        -n $StagingStorageAccount `
        -l $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false `
        -o none
    if ($LASTEXITCODE -ne 0) { throw "Failed to create staging storage account '$StagingStorageAccount'." }
}

$acctKey = (& az storage account keys list -g $HybridResourceGroup -n $StagingStorageAccount --query "[0].value" -o tsv).Trim()
$containerName = "caldova-releases"
$blobName      = "CaldovaExpense-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"

& az storage container create --name $containerName --account-name $StagingStorageAccount --account-key $acctKey -o none | Out-Null
& az storage blob upload --container-name $containerName --name $blobName --file $ZipPath --account-name $StagingStorageAccount --account-key $acctKey --overwrite true -o none
if ($LASTEXITCODE -ne 0) { throw "Failed to upload '$ZipPath' to blob storage." }

$expiryUtc = (Get-Date).ToUniversalTime().AddMinutes(30).ToString("yyyy-MM-ddTHH:mmZ")
$sasToken  = (& az storage blob generate-sas --container-name $containerName --name $blobName --permissions r --expiry $expiryUtc --https-only --account-name $StagingStorageAccount --account-key $acctKey -o tsv).Trim()
$blobSasUri = "https://$StagingStorageAccount.blob.core.windows.net/$containerName/$blobName`?$sasToken"

Write-Host "[3/4] Executing remote ZIP update on '$MachineName' via Azure Arc Run Command..." -ForegroundColor Cyan
$remoteScript = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
`$tmpZip = Join-Path `$env:TEMP 'CaldovaExpense-arc-update.zip'
`$dest   = 'C:\inetpub\caldova-expense'
`$pool   = 'CaldovaExpensePool'

Invoke-WebRequest -Uri `$env:ZIP_SAS_URI -OutFile `$tmpZip -UseBasicParsing

Import-Module WebAdministration
`$savedCfg = `$null
if (Test-Path (Join-Path `$dest 'appsettings.Production.json')) {
    `$savedCfg = Get-Content (Join-Path `$dest 'appsettings.Production.json') -Raw
}

if (Test-Path "IIS:\AppPools\`$pool") {
    if ((Get-WebAppPoolState -Name `$pool).Value -eq 'Started') {
        Stop-WebAppPool -Name `$pool
        Start-Sleep -Seconds 2
    }
}

New-Item -ItemType Directory -Force -Path `$dest | Out-Null
Expand-Archive -Path `$tmpZip -DestinationPath `$dest -Force
Remove-Item -Path `$tmpZip -Force -ErrorAction SilentlyContinue

if (`$savedCfg) {
    Set-Content -Path (Join-Path `$dest 'appsettings.Production.json') -Value `$savedCfg -Encoding utf8
}

Start-WebAppPool -Name `$pool
Start-Sleep -Seconds 2
`$resp = Invoke-WebRequest -Uri 'http://localhost:$Port/api/health' -UseBasicParsing -TimeoutSec 15
Write-Output "Deployed $blobName -> HTTP `$(`$resp.StatusCode): `$(`$resp.Content)"
"@

$runCmdName = "caldova-deploy-zip"
$runResultRaw = & az connectedmachine run-command create `
    --resource-group $HybridResourceGroup `
    --machine-name $MachineName `
    --run-command-name $runCmdName `
    --location $Location `
    --script $remoteScript `
    --protected-parameters "name=ZIP_SAS_URI" "value=$blobSasUri" `
    -o json

if ($LASTEXITCODE -ne 0) {
    throw "az connectedmachine run-command create failed."
}

$runResult = ($runResultRaw -join "`n") | ConvertFrom-Json
Write-Host "[4/4] Arc Run Command Result:" -ForegroundColor Green
Write-Host "  Execution State : $($runResult.instanceView.executionState)"
Write-Host "  Exit Code       : $($runResult.instanceView.exitCode)"
Write-Host "  Output          : $($runResult.instanceView.output)"
if ($runResult.instanceView.error) {
    Write-Warning "  Stderr          : $($runResult.instanceView.error)"
}
