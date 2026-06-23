<#
.SYNOPSIS
  Restores the secret-lane DB password from the real admin password secret.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$AppName = "quiz-secret"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[fix-secret] Restoring the secret-lane DB password from the baseline secret..." -ForegroundColor Yellow
$realPassword = Get-KvSecret -ResourceGroup $ResourceGroup -Name "db-password"
Set-KvSecret -ResourceGroup $ResourceGroup -Name "db-password-secretlane" -Value $realPassword

Write-Host "  Forcing $AppName to re-read Key Vault secret state..." -ForegroundColor Gray
$stamp = Get-Date -Format "yyyyMMddHHmmss"
az containerapp update --resource-group $ResourceGroup --name $AppName --set-env-vars FORCE_ROTATE=$stamp -o none

Write-Host "[fix-secret] Secret restored. Port 8087 authentication failures should recover." -ForegroundColor Green
