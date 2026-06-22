#Requires -Version 7.4
# Fix Bad Deploy: Roll back the regression that break-bad-deploy.ps1 shipped.
#
# Scenario 4 cleanup / agent-failure fallback. The remediation that demonstrates
# deployment-signal correlation is a rollback to the previous good revision:
#   kubectl rollout undo deployment/zava-api -n zava-demo
# This is the same action the SRE Agent runbook permits. `rollout undo` reverts
# the pod template (dropping FAULT_INJECT=500) and creates a new revision, so the
# product listing returns to HTTP 200 and the 5xx alert auto-mitigates.
#
# We also defensively clear FAULT_INJECT afterwards. If the deployment had
# multiple revisions and `undo` landed on a revision that still carried the var,
# `kubectl set env FAULT_INJECT-` guarantees a clean end state (a no-op rollout if
# already clean).
#
# Uses `az aks command invoke` (via Invoke-AksCommand) against the PRIVATE AKS
# cluster — no kubectl required from the operator's workstation.
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

# Preferred remediation: roll back to the previous good revision.
Write-Host "Rolling back: kubectl rollout undo deployment/zava-api -n $Namespace ..." -ForegroundColor Green
$undoCmd = "kubectl rollout undo deployment/zava-api -n $Namespace; kubectl rollout status deployment/zava-api -n $Namespace --timeout=180s"
$r = Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $undoCmd
if ($r.exitCode -ne 0) {
    Write-Error "kubectl rollout undo / rollout status failed (exit $($r.exitCode)). Logs: $($r.logs)"
    exit 1
}

# Defensive: ensure FAULT_INJECT is gone regardless of which revision undo landed on.
Write-Host "Ensuring FAULT_INJECT is cleared (defensive no-op if already clean)..." -ForegroundColor Green
$clearCmd = "kubectl set env deployment/zava-api FAULT_INJECT- -n $Namespace; kubectl rollout status deployment/zava-api -n $Namespace --timeout=180s"
Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $clearCmd -Quiet | Out-Null

Write-Host "Rollback complete. GET /api/products returns 200; Zava-http-5xx-errors will auto-mitigate." -ForegroundColor Green
