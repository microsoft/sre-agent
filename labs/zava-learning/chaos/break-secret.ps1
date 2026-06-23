<#
.SYNOPSIS
  Secret lane operational drift: rotates the lane-only DB password secret live.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$AppName = "quiz-secret"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[break-secret] Rotating the secret-lane DB password to an invalid value..." -ForegroundColor Yellow
$stamp = Get-Date -Format "yyyyMMddHHmmss"
Set-KvSecret -ResourceGroup $ResourceGroup -Name "db-password-secretlane" -Value "rotated-invalid-$stamp"

Write-Host "  Forcing $AppName to re-read Key Vault secret state..." -ForegroundColor Gray
az containerapp update --resource-group $ResourceGroup --name $AppName --set-env-vars FORCE_ROTATE=$stamp -o none

Write-Host "[break-secret] Live secret drift applied. The secret lane will fail DB authentication." -ForegroundColor Red
New-PagerDutyIncident -Title "Zava quiz service failing — authentication errors" `
  -Details "Students using the quiz lane on port 8087 see quiz authentication failures. Demo monitoring observed authentication errors." | Out-Null
