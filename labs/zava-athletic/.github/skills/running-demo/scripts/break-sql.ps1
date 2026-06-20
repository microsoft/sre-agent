#Requires -Version 7.4
# Break SQL: Stop PostgreSQL Flexible Server
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

Write-Host "Stopping PostgreSQL: $pgName in $ResourceGroup..." -ForegroundColor Red
az postgres flexible-server stop -g $ResourceGroup -n $pgName
Write-Host "PostgreSQL stopped. App should start returning 503 errors." -ForegroundColor Yellow
Write-Host "Azure Monitor alerts should fire within 2-5 minutes." -ForegroundColor Yellow
