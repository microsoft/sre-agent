#Requires -Version 7.4
# Break COMPOUND (Scenario 5): two independent faults with overlapping impact.
#
# This proof-of-concept combines the missing-index and bad-deploy scenarios. It
# demonstrates an evidence-based correlation pattern: use timing to find related
# candidates, then compare dependency, deployment, and database telemetry before
# assigning a common cause. The two faults in this scenario are independent.
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo",
    # Must outlast the 5-min alert window plus agent dispatch and investigation.
    # Default matches break-db-perf.ps1 so the perf fault is still live while the
    # agent works the 5xx thread (and vice versa) — if the load run ends early the
    # overlap disappears and the scenario degrades to two sequential incidents.
    [int]$LoadMinutes = 20,
    [switch]$SkipTelemetryCheck
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

Write-Host "=== Scenario 5: COMPOUND break (two independent faults) ===" -ForegroundColor Magenta
Write-Host "This injects a DB-performance fault and an APP fault so their alerts co-fire." -ForegroundColor Magenta
Write-Host "Use telemetry, not timing alone, to confirm that the causes are independent." -ForegroundColor Magenta
Write-Host ""

# Delegate to the existing single-fault scripts rather than duplicating their
# logic and keep their setup and cleanup behavior aligned.
$dbPerf = Join-Path $PSScriptRoot 'break-db-perf.ps1'
$badDeploy = Join-Path $PSScriptRoot 'break-bad-deploy.ps1'

# --- Fault A: DB performance (index drop + sustained category load) ---------
# Run this first because it restarts the API deployment. The bad-deploy revision
# must remain the latest rollout for the application investigation.
Write-Host "[1/2] Injecting DB-performance fault (drop category indexes + load)..." -ForegroundColor Yellow
$dbArgs = @{
    ResourceGroup = $ctx.ResourceGroup
    ClusterName   = $ctx.ClusterName
    Namespace     = $Namespace
    LoadMinutes   = $LoadMinutes
}
if ($SkipTelemetryCheck) { $dbArgs['SkipTelemetryCheck'] = $true }
$dbCliArgs = @(
    '-ResourceGroup', $dbArgs.ResourceGroup,
    '-ClusterName', $dbArgs.ClusterName,
    '-Namespace', $dbArgs.Namespace,
    '-LoadMinutes', $dbArgs.LoadMinutes
)
if ($SkipTelemetryCheck) { $dbCliArgs += '-SkipTelemetryCheck' }
& pwsh -NoProfile -File $dbPerf @dbCliArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "break-db-perf.ps1 failed (exit $LASTEXITCODE). Aborting before injecting the second fault so you don't end up with a half-broken environment that's hard to reason about. Fix the first fault (fix-db-perf.ps1) and retry."
    exit 1
}

# Let the perf fault establish a measurable signal before layering the app fault
# on top. Without this the two onsets land in the same telemetry bucket and even
# a careful investigation cannot separate them — which would make the scenario
# unfair rather than instructive.
Write-Host "`nWaiting 90s for the DB-perf signal to establish before the second fault..." -ForegroundColor DarkGray
Start-Sleep -Seconds 90

# --- Fault B: bad deploy (FAULT_INJECT=500 on GET /api/products) ------------
Write-Host "`n[2/2] Injecting APP fault (FAULT_INJECT=500 bad deploy)..." -ForegroundColor Yellow
& pwsh -NoProfile -File $badDeploy -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Namespace $Namespace
if ($LASTEXITCODE -ne 0) {
    Write-Error "break-bad-deploy.ps1 failed (exit $LASTEXITCODE). The DB-performance fault IS still active — run fix-db-perf.ps1 to clean up, or re-run just break-bad-deploy.ps1 to complete the compound scenario."
    exit 1
}

Write-Host ""
Write-Host "=== Compound break complete ===" -ForegroundColor Magenta
Write-Host "Expect TWO alerts within ~5-10 min: Zava-products-query-slow and Zava-http-5xx-errors." -ForegroundColor Cyan
Write-Host "They open SEPARATE investigation threads (merge is disabled on every response plan)." -ForegroundColor Cyan
Write-Host ""
Write-Host "Grading the agent:" -ForegroundColor Cyan
Write-Host "  GOOD - notices both alerts, tests whether one explains the other, finds disjoint" -ForegroundColor Green
Write-Host "         mechanisms (500 + localhost:3001 only vs PG CPU with no dep failures)," -ForegroundColor Green
Write-Host "         reports TWO independent incidents, and fixes both." -ForegroundColor Green
Write-Host "  WEAK - merges them into one story ('slow DB caused the 5xx'), fixes only the DB," -ForegroundColor Yellow
Write-Host "         and leaves FAULT_INJECT serving 500s." -ForegroundColor Yellow
Write-Host "  Also worth watching: does it discover that Zava-db-cpu-saturation is DISABLED?" -ForegroundColor Yellow
Write-Host ""
Write-Host "Fix both with: .\.github\skills\running-demo\scripts\fix-compound.ps1" -ForegroundColor Cyan
