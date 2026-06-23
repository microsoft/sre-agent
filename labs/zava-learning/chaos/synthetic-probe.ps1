<#
.SYNOPSIS
  External synthetic monitor for the Zava learner journey.

  Hits the public App Gateway frontend (portal -> courses -> quiz launch) on a loop.
  When the journey fails consistently ($Failures times in a row), it pages PagerDuty
  DIRECTLY via the REST API — no Azure Monitor in the loop.

  This exists because a connectivity blackhole (e.g. the legacy NSG DENY shipped by
  break-nsg.ps1) takes the portal fully offline, so it emits NO console logs and the
  log-based Azure Monitor alerts go blind. Synthetic monitoring catches the outage
  from the outside, the way a real student would experience it.

  The incident title is symptom-only and contains "Zava", so the SRE Agent's incident
  filter routes it to the zava-incident-responder agent for autonomous response.

.EXAMPLE
  pwsh chaos/synthetic-probe.ps1
  pwsh chaos/synthetic-probe.ps1 -Failures 3 -IntervalSec 10
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo",
  [string]$Url,
  [int]$Failures = 3,
  [int]$IntervalSec = 10,
  [int]$TimeoutSec = 8,
  [int]$MaxAttempts = 12,
  [string]$IncidentTitle = "Zava learner portal unreachable — students cannot launch quizzes"
)
. "$PSScriptRoot\_common.ps1"

$incident = Invoke-SyntheticGate -ResourceGroup $ResourceGroup -Url $Url `
  -Failures $Failures -IntervalSec $IntervalSec -TimeoutSec $TimeoutSec `
  -MaxAttempts $MaxAttempts -IncidentTitle $IncidentTitle

if ($incident) {
  Write-Host "[synthetic] Paged. PagerDuty incident '$($incident.id)' -> routed to zava-incident-responder by title match 'Zava'." -ForegroundColor Cyan
  exit 0
} else {
  Write-Host "[synthetic] No page raised (journey healthy or did not fail consistently)." -ForegroundColor Green
  exit 2
}
