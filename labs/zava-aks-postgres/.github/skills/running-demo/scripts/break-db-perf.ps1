#Requires -Version 7.4
# Break DB Performance: Drop critical category lookup index to cause slow product queries
# Runs the DDL inside an app pod via `az aks command invoke` (the pod has
# private DNS + workload identity to PG; PG is on a private VNet-delegated
# subnet so direct workstation access is impossible).
#
# Uses the in-image `bin/run-sql.js` helper — same path the SRE Agent runbook
# (sre-config/skills/performance-incidents.md) tells the agent to use, so this script
# exercises the exact remediation surface the agent has.
param(
    [string]$ResourceGroup = "",
    [string]$ClusterName = "",
    [string]$Namespace = "zava-demo",
    # Generate background category-page load so the Zava-products-query-slow alert
    # actually fires. The alert KQL excludes the 1Hz __probe endpoint by design,
    # so without real /api/products/category/<X> traffic the AvgDurationMs stays
    # near 3ms (cached) and the 30ms threshold is never crossed. Default 15 min
    # covers the alert's 5-min eval window plus agent dispatch + remediation.
    [int]$LoadMinutes = 15,
    [switch]$NoLoad,
    # Skip the AppRequests precheck (fail-loud telemetry validator). Only use
    # if you know the workspace is intentionally empty (e.g. brand-new deploy
    # before the api has had time to send any AppRequests).
    [switch]$SkipTelemetryCheck
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\..\..\..\scripts\_aks-helpers.ps1"
$ctx = Resolve-AksContext -ResourceGroup $ResourceGroup -ClusterName $ClusterName

# Azure Monitor's stateful per-rule instance is separate from agent-side merge.
# Refuse to inject a new fault while the prior condition is still Fired, and
# close a resolved prior instance so this run dispatches as a fresh alert.
Reset-DemoAlertRule -ResourceGroup $ctx.ResourceGroup -AlertRuleName 'Zava-products-query-slow'

# Confirm the alert's data source before changing the database. Query failures
# and an empty result both stop the scenario, but need different diagnostics.
if (-not $SkipTelemetryCheck) {
    Write-Host "Verifying telemetry pipeline (AppRequests in last 10 min)..." -ForegroundColor Cyan
    Assert-ZavaRequestTelemetry -ResourceGroup $ctx.ResourceGroup
}

# Remove both existing category indexes so neither masks the missing-index
# scenario. The cleanup script restores both baseline definitions.
Write-Host "Dropping category indexes (composite + single-col) via kubectl exec deploy/zava-api -- node bin/run-sql.js ..." -ForegroundColor Red

$sql = "DROP INDEX IF EXISTS idx_products_category_name; DROP INDEX IF EXISTS idx_products_category"
# Single-quote the SQL: PowerShell's native arg passing on Windows strips embedded
# double quotes when calling az.exe, which causes az to treat words after the first
# space as positional args ("unrecognized arguments"). Single quotes survive intact
# and bin/run-sql.js sees the SQL as one argv entry.
$cmd = "kubectl exec -n $Namespace deploy/zava-api -- node bin/run-sql.js '$sql'"
$r = Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $cmd

if ($r.exitCode -ne 0) {
    Write-Host "ERROR: Operation failed (exit $($r.exitCode))" -ForegroundColor Red
    exit 1
}

Write-Host "Indexes dropped. Forcing api rollout to clear PG plan cache + restart OTel exporter..." -ForegroundColor Yellow
# Restart the API to refresh PostgreSQL query plans and the telemetry exporter
# before starting the load run.
$rollCmd = "kubectl rollout restart deploy/zava-api -n $Namespace; kubectl rollout status deploy/zava-api -n $Namespace --timeout=180s"
$rr = Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $rollCmd
if ($rr.exitCode -ne 0) {
    Write-Error "kubectl rollout restart deploy/zava-api failed (exit $($rr.exitCode)). Logs: $($rr.logs)"
    exit 1
}

Write-Host "Api rolled. Category product queries will now seq_scan." -ForegroundColor Yellow

if (-not $NoLoad) {
    # Run the load generator as a Kubernetes Job (k8s/jobs/load-categories.yaml)
    # rather than a local Start-ThreadJob. Two big wins:
    #   1. Survives the script process. The Copilot-CLI / azd-hook environment
    #      recycles the powershell process between calls, which killed the
    #      previous in-process ThreadJob ~immediately, so almost no traffic
    #      reached the API and the alert never had data to evaluate.
    #   2. Removes the operator's workstation from the network path. Hits cluster-internal
    #      Service DNS (zava-api.zava-demo.svc.cluster.local) — no ingress,
    #      no corp VPN, no public LB hop.
    # ACR_NAME comes from azd env (azd hook sets it; manual runs fall back to
    # `azd env get-value`). The image already lives on every node that runs
    # the API, so no extra image pull.
    $acr = [Environment]::GetEnvironmentVariable("ACR_NAME")
    if (-not $acr) {
        try { $acr = (azd env get-value ACR_NAME 2>$null).Trim() } catch {}
    }
    if (-not $acr) {
        # Last-ditch: discover from the resource group.
        $acr = (az acr list -g $ctx.ResourceGroup --query '[0].name' -o tsv 2>$null)
    }
    if (-not $acr) {
        # The slow-query alert requires sustained traffic. Stop when the load
        # generator cannot be configured unless -NoLoad was explicitly chosen.
        Write-Error "Could not resolve ACR_NAME (azd env, ACR_NAME env, and 'az acr list' all returned empty). Either re-run inside an azd env, set ACR_NAME, or pass -NoLoad to skip the load generator."
        exit 1
    } else {
        $tplPath = Join-Path $PSScriptRoot "..\..\..\..\k8s\jobs\load-categories.yaml"
        $yaml = (Get-Content -Raw $tplPath) `
            -replace '\$\{ACR_NAME\}', $acr `
            -replace '\$\{DURATION_MIN\}', "$LoadMinutes"
        $tmp = New-TemporaryFile
        # Job manifest needs .yaml suffix so kubectl recognizes it; New-TemporaryFile
        # gives .tmp, so rename in place.
        $jobFile = [System.IO.Path]::ChangeExtension($tmp.FullName, '.yaml')
        Move-Item -Force $tmp.FullName $jobFile
        Set-Content -Path $jobFile -Value $yaml -Encoding ascii

        Write-Host "Launching in-cluster load Job for $LoadMinutes min (zava-cat-load, 10 concurrent fetches)..." -ForegroundColor Cyan
        # Pre-delete any lingering Job from a previous run (TTL is 60s but a
        # repeat invocation within that window would hit "AlreadyExists").
        # --ignore-not-found is idempotent; --wait ensures we don't race
        # the apply against the delete finalizers.
        $delCmd = "kubectl delete job zava-cat-load -n $Namespace --ignore-not-found --wait=true"
        Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $delCmd -Quiet | Out-Null

        $applyCmd = "kubectl apply -f $(Split-Path -Leaf $jobFile)"
        $jr = Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName -Command $applyCmd -Files @($jobFile) -Quiet
        Remove-Item -Force $jobFile -ErrorAction SilentlyContinue
        if ($jr.exitCode -ne 0) {
            # Same reasoning as the ACR-not-found case: a silent skip here
            # leaves Scenario 3 with no load and no alert.
            Write-Error "Job apply failed (exit $($jr.exitCode)). Load generator did not start; Scenario 3 will not produce the slow-query alert. Pass -NoLoad to bypass intentionally."
            exit 1
        } else {
            Write-Host "Load Job applied. Tail logs with:" -ForegroundColor Cyan
            Write-Host "  az aks command invoke -g $($ctx.ResourceGroup) -n $($ctx.ClusterName) --command 'kubectl logs -n $Namespace -l job-name=zava-cat-load --tail=20'" -ForegroundColor DarkGray
            Write-Host "Stop early (the fix script does this for you):" -ForegroundColor Cyan
            Write-Host "  az aks command invoke -g $($ctx.ResourceGroup) -n $($ctx.ClusterName) --command 'kubectl delete job zava-cat-load -n $Namespace'" -ForegroundColor DarkGray
        }
    }
}

Write-Host "Fix with: .\.github\skills\running-demo\scripts\fix-db-perf.ps1" -ForegroundColor Cyan
