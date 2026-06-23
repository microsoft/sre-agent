<#
.SYNOPSIS
  Restores the quiz-app lane after the "no healthy instances" fault: re-enforces a non-zero
  scale floor in IaC and brings the live revision back so the lane serves quiz content again.

  The acute fault deactivates the lane's active revision, so recovery REACTIVATES the most
  recently deactivated revision (an `az containerapp update` with unchanged config is a no-op
  in single-revision mode and would NOT bring a deactivated revision back).
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$AppName = "quiz-app"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[fix-app] Restoring the quiz-app replica baseline..." -ForegroundColor Yellow

Write-Host "  1/2 Committing healthy release (quiz-app min replicas -> 1) to GitHub..." -ForegroundColor Gray
$c1 = Set-ParamLine -Pattern '"appLaneMinReplicas"\s*:\s*\{\s*"value"\s*:\s*0\s*\}' `
                    -Replacement '"appLaneMinReplicas": { "value": 1 }'
if ($c1) { Invoke-GitPush -Message "Restore quiz app lane scale floor" }
else { Write-Host "  (quiz-app min replicas already 1 in source)" -ForegroundColor DarkGray }

Write-Host "  2/2 Reactivating the live quiz-app revision..." -ForegroundColor Gray
# `az containerapp revision list` (without --all) only returns ACTIVE revisions, so a
# deactivated revision is invisible there. Target the latest revision explicitly and
# reactivate it only if it is currently inactive (idempotent).
$latest = az containerapp show -g $ResourceGroup -n $AppName --query "properties.latestRevisionName" -o tsv
if (-not $latest) {
  Write-Host "[fix-app] ERROR: could not resolve the latest revision for $AppName." -ForegroundColor Red
  exit 1
}
$active = az containerapp revision show -g $ResourceGroup -n $AppName --revision $latest --query "properties.active" -o tsv
if ($active -eq 'false') {
  az containerapp revision activate -g $ResourceGroup -n $AppName --revision $latest -o none
  Write-Host "[fix-app] Reactivated revision $latest. Port 8083 quiz launches should recover." -ForegroundColor Green
} else {
  Write-Host "[fix-app] Latest revision $latest is already active — lane already serving." -ForegroundColor Green
}
