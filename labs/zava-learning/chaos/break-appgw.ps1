<#
.SYNOPSIS
  App Gateway lane probe fault, shipped FROM IaC.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[break-appgw] Shipping the bad quiz-appgw probe path from IaC..." -ForegroundColor Yellow

Write-Host "  1/2 Committing bad release (appgwLaneProbePath=/status-ping) to GitHub..." -ForegroundColor Gray
$changed = Set-ParamLine -Pattern '"appgwLaneProbePath"\s*:\s*\{\s*"value"\s*:\s*"/health"\s*\}' `
                         -Replacement '"appgwLaneProbePath": { "value": "/status-ping" }'
if ($changed) { Invoke-GitPush -Message "Update quiz appgw lane health probe path" }
else { Write-Host "  (appgwLaneProbePath already /status-ping in source)" -ForegroundColor DarkGray }

Write-Host "  2/2 Updating the live quiz-appgw health probe to /status-ping..." -ForegroundColor Gray
$gatewayName = Get-AppGwName -ResourceGroup $ResourceGroup
$live = Set-AppGwProbePath -ResourceGroup $ResourceGroup -GatewayName $gatewayName `
                           -ProbeName "quiz-appgw-health" -Path "/status-ping"
if (-not $live) {
  Write-Host "[break-appgw] FAILED: the live probe did not change to /status-ping (gateway busy or error)." -ForegroundColor Red
  Write-Host "             The fault is NOT live; not paging PagerDuty. Re-run break-appgw." -ForegroundColor Red
  exit 1
}

Write-Host "[break-appgw] Fault live + in source. The gateway marks the quiz-appgw backend unhealthy." -ForegroundColor Red
New-PagerDutyIncident -Title "Zava portal returning 502s — students see errors" `
  -Details "Students using the quiz lane on port 8082 see gateway errors. Demo monitoring observed the student-facing failure." | Out-Null
