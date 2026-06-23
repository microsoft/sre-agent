<#
.SYNOPSIS
  App lane "no healthy instances" fault.

  Latent cause (IaC): the quiz-app lane's scale floor is dropped to zero (appLaneMinReplicas: 0),
  so nothing guarantees a running replica. Acute trigger (live): the lane's active Container Apps
  revision is deactivated, leaving zero replicas to answer requests.

  NOTE: Azure Container Apps forbids maxReplicas=0, so a real "scaled to zero" outage cannot be
  produced with `az containerapp update --max-replicas 0`. Deactivating the active revision is the
  only valid way to hold the lane at zero healthy replicas under live traffic; fix-app.ps1 reverses
  it by reactivating the revision.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$AppName = "quiz-app"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[break-app] Shipping the quiz-app scale-floor-removed config from IaC..." -ForegroundColor Yellow

Write-Host "  1/2 Committing bad release (quiz-app min replicas -> 0) to GitHub..." -ForegroundColor Gray
$c1 = Set-ParamLine -Pattern '"appLaneMinReplicas"\s*:\s*\{\s*"value"\s*:\s*1\s*\}' `
                    -Replacement '"appLaneMinReplicas": { "value": 0 }'
if ($c1) { Invoke-GitPush -Message "Drop quiz app lane scale floor to zero" }
else { Write-Host "  (quiz-app min replicas already 0 in source)" -ForegroundColor DarkGray }

Write-Host "  2/2 Forcing the live quiz-app revision to zero replicas..." -ForegroundColor Gray
$revs = az containerapp revision list -g $ResourceGroup -n $AppName -o json | ConvertFrom-Json
$active = @($revs | Where-Object { $_.properties.active }) | Select-Object -First 1
if (-not $active) {
  Write-Host "[break-app] ERROR: no active revision on $AppName — fault NOT applied; not paging." -ForegroundColor Red
  exit 1
}
az containerapp revision deactivate -g $ResourceGroup -n $AppName --revision $active.name -o none
Start-Sleep -Seconds 8
$still = az containerapp revision show -g $ResourceGroup -n $AppName --revision $active.name --query "properties.active" -o tsv
if ($still -ne 'false') {
  Write-Host "[break-app] ERROR: revision $($active.name) still active — scale-to-zero did NOT take effect; not paging PagerDuty." -ForegroundColor Red
  exit 1
}

Write-Host "[break-app] Fault live + in source. The app lane has no quiz-service replicas (revision $($active.name) deactivated)." -ForegroundColor Red
New-PagerDutyIncident -Title "Zava quiz service unavailable — launches failing" `
  -Details "Students using the quiz lane on port 8083 cannot launch quizzes. Demo monitoring observed the student-facing failure." | Out-Null
