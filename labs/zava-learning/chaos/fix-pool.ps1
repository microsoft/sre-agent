<#
.SYNOPSIS
  Restores the app_pool role connection limit and refreshes quiz-pool.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$AppName = "quiz-pool"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[fix-pool] Restoring the app_pool connection baseline..." -ForegroundColor Yellow
Invoke-PgSql -ResourceGroup $ResourceGroup -Database "zava" `
  -Sql "ALTER ROLE app_pool CONNECTION LIMIT -1;"

Write-Host "  Refreshing $AppName so held connections drain..." -ForegroundColor Gray
$stamp = Get-Date -Format "yyyyMMddHHmmss"
az containerapp update --resource-group $ResourceGroup --name $AppName --set-env-vars FORCE_RECONNECT=$stamp -o none

Write-Host "[fix-pool] Role restored. Port 8086 intermittent failures should recover." -ForegroundColor Green
