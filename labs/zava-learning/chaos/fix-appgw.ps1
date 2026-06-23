<#
.SYNOPSIS
  Restores the quiz-appgw health probe path and healthy IaC parameter.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[fix-appgw] Restoring the quiz-appgw probe baseline..." -ForegroundColor Yellow

Write-Host "  1/2 Committing healthy release (appgwLaneProbePath=/health) to GitHub..." -ForegroundColor Gray
$changed = Set-ParamLine -Pattern '"appgwLaneProbePath"\s*:\s*\{\s*"value"\s*:\s*"/status-ping"\s*\}' `
                         -Replacement '"appgwLaneProbePath": { "value": "/health" }'
if ($changed) { Invoke-GitPush -Message "Restore quiz appgw lane health probe path" }
else { Write-Host "  (appgwLaneProbePath already /health in source)" -ForegroundColor DarkGray }

Write-Host "  2/2 Updating the live quiz-appgw health probe to /health..." -ForegroundColor Gray
$gatewayName = Get-AppGwName -ResourceGroup $ResourceGroup
$live = Set-AppGwProbePath -ResourceGroup $ResourceGroup -GatewayName $gatewayName `
                           -ProbeName "quiz-appgw-health" -Path "/health"
if (-not $live) {
  Write-Host "[fix-appgw] WARNING: could not confirm the live probe reverted to /health — retry fix-appgw." -ForegroundColor Red
  exit 1
}

Write-Host "[fix-appgw] Probe restored. Port 8082 quiz launches should recover." -ForegroundColor Green
