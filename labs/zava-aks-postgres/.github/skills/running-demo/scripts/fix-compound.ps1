#Requires -Version 7.4
# Fix COMPOUND (Scenario 5): undo both independent faults.
#
# Post-demo cleanup / fallback, exactly like the other fix scripts — during a
# live demo you want the SRE Agent to remediate, not this script.
#
# Order matters for a clean readout: undo the APP fault first so GET /api/products
# stops returning 500, THEN recreate the indexes and stop the load generator. Doing
# it the other way round leaves the app serving 500s while latency has already
# recovered, which looks like the DB fix caused an app regression.
#
# Both cleanup steps run independently so one failure does not prevent the other
# scenario from being restored.
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

Write-Host "=== Scenario 5: COMPOUND fix (undo both faults) ===" -ForegroundColor Magenta

$failures = @()

# --- Undo Fault B: bad deploy ----------------------------------------------
Write-Host "`n[1/2] Reverting APP fault (rollout undo + strip FAULT_INJECT)..." -ForegroundColor Yellow
try {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'fix-bad-deploy.ps1') -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Namespace $Namespace
    if ($LASTEXITCODE -ne 0) { $failures += "fix-bad-deploy.ps1 (exit $LASTEXITCODE)" }
} catch {
    $failures += "fix-bad-deploy.ps1 ($($_.Exception.Message))"
}

# --- Undo Fault A: DB performance ------------------------------------------
# Continue regardless of the result above so we never strand the index drop.
Write-Host "`n[2/2] Reverting DB-performance fault (recreate indexes + stop load Job)..." -ForegroundColor Yellow
try {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'fix-db-perf.ps1') -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Namespace $Namespace
    if ($LASTEXITCODE -ne 0) { $failures += "fix-db-perf.ps1 (exit $LASTEXITCODE)" }
} catch {
    $failures += "fix-db-perf.ps1 ($($_.Exception.Message))"
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Error "Compound fix completed with failures: $($failures -join '; '). Re-run the individual fix script(s) above — both are idempotent. Verify manually: GET /api/products returns 200, and both idx_products_category and idx_products_category_name exist."
    exit 1
}

Write-Host "=== Compound fix complete ===" -ForegroundColor Magenta
Write-Host "Verify: GET /api/products returns 200, category endpoints back to ~3ms, PG cpu_percent back to baseline." -ForegroundColor Cyan
Write-Host "Both alerts should auto-mitigate; the agent may also have closed them itself." -ForegroundColor Cyan
