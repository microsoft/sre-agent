#Requires -Version 7.4
# Break Bad Deploy: Ship a bad config rollout that regresses the product listing.
#
# Scenario 4 — Bad Deploy / Rollback (deployment-signal correlation).
#
# Set FAULT_INJECT=500 through `kubectl set env` to create a new rollout revision.
# The investigation can compare the 5xx onset with rollout history and KubeEvents,
# then restore the previous revision with `kubectl rollout undo`.
#
# Detection reuses the existing Zava-http-5xx-errors scheduled-query alert (it
# counts failed AppRequests over the window). No external load generator needed:
# the in-cluster 1 Hz self-probe already hits GET /api/products, so the
# failed-request count crosses the threshold on its own. The liveness AND readiness
# probes both hit /livez, and /api/health stays green, so only the product route
# regresses.
#
# AKS is a PRIVATE cluster — every K8s op runs through `az aks command invoke`
# (via Invoke-AksCommand), the same path the SRE Agent uses for remediation.
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo",
    # Skip the AppRequests precheck (fail-loud telemetry validator). Only use if
    # you know the workspace is intentionally empty (e.g. a brand-new deploy
    # before the api has had time to send any AppRequests).
    [switch]$SkipTelemetryCheck
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

# Azure Monitor's stateful per-rule instance is separate from agent-side merge.
# Refuse to inject a new fault while the prior condition is still Fired, and
# close a resolved prior instance so this run dispatches as a fresh alert.
Reset-DemoAlertRule -ResourceGroup $ctx.ResourceGroup -AlertRuleName 'Zava-http-5xx-errors'

# Confirm that AppRequests telemetry is available before injecting the fault.
# Pass -SkipTelemetryCheck to bypass this guard.
if (-not $SkipTelemetryCheck) {
    Write-Host "Verifying telemetry pipeline (AppRequests in last 10 min)..." -ForegroundColor Cyan
    $ws = (az monitor log-analytics workspace list -g $ctx.ResourceGroup --query "[0].customerId" -o tsv 2>$null)
    if (-not $ws) {
        Write-Warning "Could not find Log Analytics workspace in $($ctx.ResourceGroup); skipping telemetry precheck."
    } else {
        $kql = "AppRequests | where TimeGenerated > ago(10m) | where AppRoleName == 'zava-api' | summarize n=count()"
        $raw = (az monitor log-analytics query -w $ws --analytics-query $kql 2>$null)
        $n = 0
        if ($raw) { try { $n = [int]((($raw | ConvertFrom-Json)[0].n)) } catch { $n = 0 } }
        if ($n -lt 1) {
            Write-Error "No AppRequests from zava-api were found in the last 10 minutes. Verify Application Insights configuration and ingestion, or restart the API deployment. Pass -SkipTelemetryCheck to override."
            exit 1
        }
        Write-Host "Telemetry OK ($n AppRequests in last 10 min)." -ForegroundColor Green
    }
}

# Ship the bad deploy. `kubectl set env` mutates the pod template, which creates a
# new rollout revision — that revision is the deployment signal the agent should
# correlate the regression against.
Write-Host "Shipping bad config rollout: kubectl set env deployment/zava-api FAULT_INJECT=500 ..." -ForegroundColor Red
$setCmd = "kubectl set env deployment/zava-api FAULT_INJECT=500 -n $Namespace; kubectl rollout status deployment/zava-api -n $Namespace --timeout=180s"
$r = Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $setCmd
if ($r.exitCode -ne 0) {
    Write-Error "kubectl set env / rollout status failed (exit $($r.exitCode)). Logs: $($r.logs)"
    exit 1
}

Write-Host "Bad deploy rolled out. GET /api/products now returns HTTP 500; /livez and /api/health stay green." -ForegroundColor Yellow
Write-Host "What to watch:" -ForegroundColor Cyan
Write-Host "  - Zava-http-5xx-errors scheduled-query alert fires (failed AppRequests > threshold) within ~5 min." -ForegroundColor DarkGray
Write-Host "  - The SRE Agent should correlate the 5xx spike with the recent rollout:" -ForegroundColor DarkGray
Write-Host "      kubectl rollout history deployment/zava-api -n $Namespace" -ForegroundColor DarkGray
Write-Host "      kubectl get events -n $Namespace  (KubeEvents: ScalingReplicaSet)" -ForegroundColor DarkGray
Write-Host "  - Remediation is a rollback to the previous good revision: kubectl rollout undo." -ForegroundColor DarkGray
Write-Host "Fix with: .\.github\skills\running-demo\scripts\fix-bad-deploy.ps1" -ForegroundColor Cyan
