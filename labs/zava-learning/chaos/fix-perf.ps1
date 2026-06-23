<#
.SYNOPSIS
  Restores quiz-service v1.0 source and deploys a clean image to the perf lane.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$AppName = "quiz-perf"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[fix-perf] Restoring quiz-service v1.0 to the perf lane..." -ForegroundColor Yellow

Write-Host "  1/2 Restoring pristine quiz-service source + committing to GitHub..." -ForegroundColor Gray
$changed = Restore-QuizPerf
if ($changed) { Invoke-GitPush -Message "restore: quiz-service v1.0 baseline" -Files @("src\quiz-service\server.js") }
else { Write-Host "  (quiz-service source already clean)" -ForegroundColor DarkGray }

Write-Host "  2/2 Building + deploying a clean quiz-service image to $AppName..." -ForegroundColor Gray
$tag = "v1.0-" + (Get-Date -Format "yyyyMMddHHmmss")
$img = Build-And-DeployLane -ResourceGroup $ResourceGroup -SrcFolder "quiz-service" -AppName $AppName -Tag $tag

Write-Host "[fix-perf] Clean image live ($img). Port 8084 latency should recover." -ForegroundColor Green
