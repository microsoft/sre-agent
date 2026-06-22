#Requires -Version 7.4
# Break Bad Deploy: Ship a bad config rollout that regresses the product listing.
#
# Scenario 4 — Bad Deploy / Rollback (deployment-signal correlation).
#
# This simulates the most common real-world incident: a regression introduced by
# a deployment, not by infra. We flip the app's FAULT_INJECT env var to 500 via
# `kubectl set env`, which mutates the Deployment's pod template and triggers a
# NEW rollout revision. That revision IS the deployment signal — the agent is
# expected to correlate the 5xx spike with `kubectl rollout history` / KubeEvents
# and roll back with `kubectl rollout undo` (the fix script does the same).
#
# Detection reuses the existing Zava-http-5xx-errors metric alert (requests/failed
# on App Insights). No new alert, no external load generator: the in-cluster 1 Hz
# self-probe already hits GET /api/products, so once that route returns 500 the
# failed-request count crosses the threshold on its own. Liveness (/livez) and
# readiness (/api/health) are deliberately untouched, so pods stay Running and
# only the app route regresses — exactly the "looks healthy at the platform layer
# but the app is broken" shape that makes deployment correlation the key signal.
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

# Telemetry precheck. Zava-http-5xx-errors evaluates the requests/failed metric,
# which is derived from AppRequests telemetry. If the api isn't currently sending
# telemetry to the workspace, the alert can never fire no matter how many 500s the
# route returns, and the demo silently fails (looks like "agent ignored an alert"
# 30 min later). Fail loudly *before* the break. Pass -SkipTelemetryCheck to bypass.
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
            Write-Error "Telemetry pipeline is dead: 0 AppRequests from zava-api in the last 10 min. Zava-http-5xx-errors evaluates the requests/failed metric (derived from AppRequests) — without telemetry it can never fire and the SRE Agent will never be dispatched. Possible causes: OTel exporter wedged in api pods, App Insights ingestion throttled, wrong APPLICATIONINSIGHTS_CONNECTION_STRING. Try ``kubectl rollout restart deploy/zava-api -n $Namespace`` to restart the exporter. Pass -SkipTelemetryCheck to override."
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
Write-Host "  - Zava-http-5xx-errors metric alert fires (requests/failed > threshold) within ~5 min." -ForegroundColor DarkGray
Write-Host "  - The SRE Agent should correlate the 5xx spike with the recent rollout:" -ForegroundColor DarkGray
Write-Host "      kubectl rollout history deployment/zava-api -n $Namespace" -ForegroundColor DarkGray
Write-Host "      kubectl get events -n $Namespace  (KubeEvents: ScalingReplicaSet)" -ForegroundColor DarkGray
Write-Host "  - Remediation is a rollback to the previous good revision: kubectl rollout undo." -ForegroundColor DarkGray
Write-Host "Fix with: .\.github\skills\running-demo\scripts\fix-bad-deploy.ps1" -ForegroundColor Cyan
