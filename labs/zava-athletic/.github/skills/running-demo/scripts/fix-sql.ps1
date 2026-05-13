#Requires -Version 7.4
# Fix SQL: Start PostgreSQL Flexible Server (idempotent — skips when already Ready)
param([string]$ResourceGroup = "")

# Auto-detect from azd env
$azdRG = ""
try {
    $envText = azd env get-values 2>$null
    if ($envText) {
        $envText | ForEach-Object {
            if ($_ -match '^RESOURCE_GROUP="?([^"]*)"?$') { $azdRG = $Matches[1] }
        }
    }
} catch {}
if (-not $ResourceGroup) {
    if ($azdRG) { $ResourceGroup = $azdRG }
    else { Write-Error "RESOURCE_GROUP not resolved. Pass -ResourceGroup or run inside an azd env."; exit 1 }
}

$pgName = az postgres flexible-server list -g $ResourceGroup --query "[0].name" -o tsv
if (-not $pgName) { Write-Error "No PostgreSQL server found in $ResourceGroup"; exit 1 }

# Idempotency: don't call `start` against an already-running server (azure-cli
# returns InvalidParameterValue and exits non-zero, which trips $ErrorActionPreference).
$pgState = az postgres flexible-server show -g $ResourceGroup -n $pgName --query state -o tsv 2>$null
if ($pgState -eq "Ready") {
    Write-Host "PostgreSQL $pgName already Ready — nothing to do." -ForegroundColor Green
    exit 0
}

Write-Host "Starting PostgreSQL: $pgName in $ResourceGroup (current state: $pgState)..." -ForegroundColor Green
az postgres flexible-server start -g $ResourceGroup -n $pgName
Write-Host "PostgreSQL started. App should recover within 30 seconds." -ForegroundColor Green
