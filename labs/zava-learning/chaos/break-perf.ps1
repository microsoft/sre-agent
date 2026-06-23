<#
.SYNOPSIS
  Perf lane regression, shipped as a real quiz-service code/image release.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$AppName = "quiz-perf"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[break-perf] Shipping quiz-service v1.1 to the perf lane..." -ForegroundColor Yellow

Write-Host "  1/2 Swapping in the v1.1 source variant + committing to GitHub..." -ForegroundColor Gray
$changed = Swap-QuizPerf
if ($changed) { Invoke-GitPush -Message "release: v1.1 tamper-evident quiz integrity receipts" -Files @("src\quiz-service\server.js") }
else { Write-Host "  (quiz-service v1.1 already present in source)" -ForegroundColor DarkGray }

Write-Host "  2/2 Building + deploying the bad quiz-service image to $AppName..." -ForegroundColor Gray
$tag = "v1.1-" + (Get-Date -Format "yyyyMMddHHmmss")
$img = Build-And-DeployLane -ResourceGroup $ResourceGroup -SrcFolder "quiz-service" -AppName $AppName -Tag $tag

Write-Host "[break-perf] Regression live ($img). The perf lane now does synchronous integrity receipts." -ForegroundColor Red
New-PagerDutyIncident -Title "Zava quiz launches slow — elevated latency" `
  -Details "Students using the quiz lane on port 8084 experience slow quiz launches. Demo monitoring observed elevated latency." | Out-Null
