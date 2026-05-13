#Requires -Version 7.4
# Fix DB Performance: Recreate the critical category lookup index
# Runs the DDL inside an app pod via `az aks command invoke` (PG is private).
#
# Uses the in-image `bin/run-sql.js` helper — same path the SRE Agent runbook
# (infra/modules/sre-agent.bicep) tells the agent to use for autonomous
# remediation of Scenario 3 (missing index).
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

Write-Host "Recreating category indexes (composite + single-col) via kubectl exec deploy/zava-api -- node bin/run-sql.js ..." -ForegroundColor Green

# Recreate both indexes that break-db-perf.ps1 dropped. CONCURRENTLY can't be
# used inside a multi-statement transaction block, so issue them in two
# separate run-sql.js calls (each runs as its own implicit transaction).
$sqls = @(
    "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_category_name ON products(category, name)",
    "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_category ON products(category)"
)
foreach ($sql in $sqls) {
    # Single-quote the SQL: PowerShell's native arg passing on Windows strips embedded
    # double quotes when calling az.exe. Single quotes survive intact and bin/run-sql.js
    # sees the SQL as one argv entry. (Same fix as break-db-perf.ps1.)
    $cmd = "kubectl exec -n $Namespace deploy/zava-api -- node bin/run-sql.js '$sql'"
    $r = Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $cmd
    if ($r.exitCode -ne 0) {
        Write-Host "ERROR: Operation failed (exit $($r.exitCode)) for: $sql" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Indexes recreated. Product catalog queries will return to normal speed." -ForegroundColor Green

# Stop the in-cluster load Job that break-db-perf.ps1 launched. Idempotent —
# --ignore-not-found means we don't care if it's already gone (TTL controller
# may have reaped it, or the user ran -NoLoad).
$delJob = "kubectl delete job zava-cat-load -n $Namespace --ignore-not-found --wait=false"
Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $delJob -Quiet | Out-Null
