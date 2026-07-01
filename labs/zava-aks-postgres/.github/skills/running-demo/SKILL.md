---
name: running-demo
description: Run break/fix demo scenarios with browser verification. Use when asked to demo, break the app, or show the SRE Agent working.
---

# Running the Demo

This skill drives the full demo using Playwright MCP for browser control. Execute each step — don't just describe them.

## Setup

```powershell
# AKS is a private cluster — kubectl from your local workstation won't work without VPN/jumpbox.
# Use `Invoke-AksCommand` (wraps `az aks command invoke` for human-operator polling/diagnostics).
# The SRE Agent uses native kubectl; this helper is for human operators without the agent's VNet/DNS/proxy setup.
. .\scripts\_aks-helpers.ps1
$rg  = (azd env get-value RESOURCE_GROUP)
$aks = (azd env get-value AKS_CLUSTER_NAME)
$pg  = (az postgres flexible-server list -g $rg --query '[0].name' -o tsv)
$r = Invoke-AksCommand -ResourceGroup $rg -ClusterName $aks `
    -Command "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" -Quiet
$ip = ($r.logs -replace '[^\d\.]','').Trim()
$storeUrl = "http://$ip"
$agentUrl = (azd env get-value AGENT_PORTAL_URL)  # deep-links to this agent's blade — sign in if prompted
```

## Scenario 1: Database Outage

### Step 1: Show healthy state
1. Use Playwright MCP to navigate to `$storeUrl`
2. Take a screenshot — show products loading, status bar says "ALL SYSTEMS OPERATIONAL"
3. Navigate to `$storeUrl/api/health` — show `"status":"healthy","db_connected":true`

### Step 2: Break it
```powershell
.\.github\skills\running-demo\scripts\break-sql.ps1
```
Wait 30 seconds for the app to notice.

### Step 3: Show the break in the browser
1. Navigate to `$storeUrl` — should show "SERVICE DISRUPTION" overlay
2. Take a screenshot — this is the degraded UI the audience should see
3. Navigate to `$storeUrl/api/health` — show `"status":"unhealthy","db_connected":false`

### Step 4: Watch the SRE Agent
1. Navigate to `$agentUrl` — the agent portal
2. Look for a new incident thread (`postgres-unreachable` scheduled-query alert, routed to the `zava-database` response plan)
3. The agent should investigate and run `az postgres flexible-server start`
4. Poll PostgreSQL state every 60s — let the agent do its thing, do NOT run the fix script:
   ```powershell
   az postgres flexible-server show -g $rg -n $pg --query state -o tsv
   ```
5. Wait until state = "Ready" (typically 3-5 min)
6. There's now **one** `postgres-unreachable` alert for both DB scenarios, with the `zava-database` response plan **merge disabled** (the agent won't fold a second incident into the first thread). Both scenarios share that single rule, so Azure Monitor won't emit a fresh alert instance while the previous one is still `Fired`/`Acknowledged`. To keep back-to-back runs clean, the `database-incidents` runbook has the agent **close the `postgres-unreachable` alert as its final step** once recovery is verified — so by the time you start Scenario 2 it should already be resolved and the new break dispatches fresh. (Fallback if the agent didn't close it: `autoMitigate` resolves it ~15-30 min after recovery, or close it yourself in the portal Alerts blade.) The agent diagnoses each from ARM state (`Stopped` → restart; `Ready` but unreachable → NetworkPolicy/NSG).

### Step 5: Show recovery
1. Wait 15s after PG is Ready for pods to reconnect
2. Navigate to `$storeUrl` — products should load again
3. Take a screenshot — show recovery

Do not run `fix-sql.ps1` as part of the demo. It exists for post-demo cleanup or developer iteration only — running it during the demo invalidates the result. If the agent doesn't fix the incident, that *is* the result; show it and move on.

## Scenario 2: Network Partition

### Step 1: Show healthy state
1. Navigate to `$storeUrl` — confirm healthy
2. Take screenshot

### Step 2: Break it

> **Heads-up if you just ran Scenario 1:** both DB scenarios share the one `postgres-unreachable` alert. The `database-incidents` runbook has the agent close that alert as its final remediation step, so it should already be resolved and this break will dispatch a fresh investigation. If the agent didn't close it (still `Fired`), close it in the portal Alerts blade or wait for `autoMitigate` (~15-30 min) — otherwise Azure Monitor dedupes this break into the still-open instance and the agent won't dispatch.

```powershell
.\.github\skills\running-demo\scripts\break-network.ps1
```
Wait 30 seconds.

### Step 3: Show the break
1. Navigate to `$storeUrl` — should show "SERVICE DISRUPTION" with ETIMEDOUT errors
2. Take screenshot — note: error says "timeout" not "connection refused" (server is up but unreachable)

### Step 4: Watch the agent
1. Check SRE Agent portal for investigation
2. Agent needs to find the K8s NetworkPolicy via native `kubectl get networkpolicy -n zava-demo -o yaml` and remove it via `kubectl delete networkpolicy database-tier-isolation -n zava-demo` (run in its sandbox terminal) — this is harder than Scenario 1 and may take longer
3. Poll for NetworkPolicy removal (the AKS API server is private — go through ARM):
   ```powershell
   Invoke-AksCommand -ResourceGroup $rg -ClusterName $aks -Command "kubectl get networkpolicy -n zava-demo"
   ```
4. Do not run `fix-network.ps1` as part of the demo — same rule as Scenario 1: the script is post-demo cleanup, not an agent-failure fallback.

### Step 5: Show recovery
1. Navigate to `$storeUrl` — products load
2. Take screenshot

## Scenario 3: Missing Index

### Step 1: Show healthy state
1. Navigate to `$storeUrl` — confirm healthy

### Step 2: Break it
```powershell
# Drops idx_products_category_name AND idx_products_category (the single-column
# index alone is enough to keep queries under the 30ms alert threshold via
# index range scan + sort, so both must go to force seq_scan). Also rolls the
# api deployment to clear PG plan cache + restart the OTel exporter, then
# verifies AppRequests telemetry is flowing before launching the load Job.
# Variants are seeded automatically on first deploy (50 originals + 120,000
# size/color/edition variants from seed.js), so this is a single command.
.\.github\skills\running-demo\scripts\break-db-perf.ps1
```
If the script aborts with "Telemetry pipeline is dead", the api pods stopped sending AppRequests (we've seen the OTel exporter wedge silently after 4h+ uptime). The script's recommended `kubectl rollout restart deploy/zava-api` will normally fix it; pass `-SkipTelemetryCheck` to bypass on a brand-new deploy where the api hasn't had time to send any telemetry yet.

### Step 3: Show degraded performance
1. Navigate to `$storeUrl/api/diagnostics`
2. Look at `scan_stats` — `products` table should show `index_usage_pct: 0` with high `seq_scan` count
3. Take screenshot
4. (`break-db-perf.ps1` already launched a 15-min in-cluster Kubernetes Job (`zava-cat-load` in the `zava-demo` namespace) that hammers `/api/products/category/<X>` over the cluster-internal Service DNS. This pushes real traffic past the alert's 30ms threshold — the 1Hz `__probe` is excluded by the alert KQL. The Job auto-cleans 60s after completion via `ttlSecondsAfterFinished`; `fix-db-perf.ps1` also deletes it explicitly. Run with `-NoLoad` to skip.)

### Step 4: Watch agent
1. Monitor SRE Agent portal — it should detect slow response times via App Insights, identify the missing index, and run `CREATE INDEX CONCURRENTLY` in-cluster via `bin/run-sql.js` (the agent runs native `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js "<SQL>"` from its sandbox terminal — the helper reuses the pod's workload identity)
2. Do not run `fix-db-perf.ps1` as part of the demo — same rule as the other scenarios: the script is post-demo cleanup, not an agent-failure fallback.

### Step 5: Show recovery
1. Verify the index has been recreated by reading the diagnostics endpoint
   (cleaner than trying to round-trip a quoted SQL literal through PowerShell →
   `az aks command invoke` → kubectl exec → node argv — embedded quotes don't
   survive that chain reliably on Windows):
   ```powershell
   $diag = Invoke-RestMethod "$storeUrl/api/diagnostics"
   $diag.indexes | Where-Object { $_.index_name -eq 'idx_products_category_name' }
   ($diag.scan_stats | Where-Object { $_.table_name -eq 'products' }).index_usage_pct
   ```
   The index row should be present and `index_usage_pct` should climb back to ~95%+
   (mirrors the direct-state checks used in Scenario 1 (`az postgres flexible-server show --query state`) and Scenario 2 (`kubectl get networkpolicy`)).
2. Navigate to `$storeUrl` — fast loading

## Scenario 4: Bad Deploy / Rollback

### Step 1: Show healthy state
1. Navigate to `$storeUrl` — confirm healthy, products load
2. Take screenshot

### Step 2: Break it
```powershell
# Ships a bad config rollout: kubectl set env deployment/zava-api FAULT_INJECT=500.
# This mutates the pod template -> a NEW rollout revision (the deployment signal),
# and GET /api/products starts returning HTTP 500. The liveness AND readiness probes
# both hit /livez (and /api/health stays green too), so pods stay Running and only the app route regresses.
# The 1Hz in-cluster self-probe hits /api/products, so the 5xx signal builds with no
# external load. Verifies AppRequests telemetry is flowing first (-SkipTelemetryCheck
# to bypass on a brand-new deploy).
.\.github\skills\running-demo\scripts\break-bad-deploy.ps1
```
If the script aborts with "Telemetry pipeline is dead", the api pods stopped sending AppRequests; `kubectl rollout restart deploy/zava-api -n zava-demo` normally fixes it, or pass `-SkipTelemetryCheck`.

### Step 3: Show the break
1. Navigate to `$storeUrl/api/products` — returns HTTP 500
2. Navigate to `$storeUrl/api/health` — still `"status":"healthy","db_connected":true` (the deploy regressed the app route, not the DB). Take a screenshot to make the point: platform-healthy, app-broken.

### Step 4: Watch the agent
1. Check the SRE Agent portal for a new incident from `Zava-http-5xx-errors`
2. The agent should rule out the DB/network/slow-query conditions, then correlate the 5xx spike with the recent rollout and roll back:
   ```powershell
   Invoke-AksCommand -ResourceGroup $rg -ClusterName $aks -Command "kubectl rollout history deployment/zava-api -n zava-demo"
   ```
3. Remediation is `kubectl rollout undo deployment/zava-api -n zava-demo` (rollback to the previous good revision)
4. Do not run `fix-bad-deploy.ps1` as part of the demo — same rule as the other scenarios: the script is post-demo cleanup, not an agent-failure fallback.

### Step 5: Show recovery
1. Navigate to `$storeUrl/api/products` — returns 200 again
2. Navigate to `$storeUrl` — products load; take screenshot

## Chat demo: interrogate the hub firewall (network device)

No break needed — this shows the agent treating the **hub Azure Firewall** as a queryable "network device" in the hub-and-spoke topology.

1. Open the agent chat (`$agentUrl`) and ask:
   > "Inspect the hub Azure Firewall: summarize its egress allow-list (rule collections), and query the `AZFW*` Log Analytics tables for anything denied for the agent subnet in the last hour."
2. Expect the agent to read the firewall policy over ARM (`az network firewall policy ...`, covered by its Reader role) and run KQL against `AZFWApplicationRule` / `AZFWNetworkRule`.
3. Optional follow-up — *"Is the firewall in the path between the app and PostgreSQL?"* The correct answer is **no**: it gates only the agent's own egress; the app↔PG path is governed by the platform-spoke NSG and the in-cluster Kubernetes NetworkPolicy. This confirms the agent has the topology boundary right.

This is a read/diagnostic demonstration, not a break/fix — the firewall gates the agent's *own* egress, so breaking it would disable the agent itself.

## Watching the SRE Agent

In a separate shell, tail the agent's reasoning live via its data-plane API:
```powershell
.\scripts\watch-agent.ps1                              # list all threads
.\scripts\watch-agent.ps1 -Show -Title slow            # full transcript of latest matching incident
.\scripts\watch-agent.ps1 -Tail -Title slow            # poll for new messages until Resolved/Closed/Mitigated
```

**Be patient.** Agent runtime varies a lot by scenario:
- S1 (PG stop): typically 3–5 min
- S2 (NetworkPolicy): can take 30 min to 3+ hours (it has to investigate the NSG red-herring + pods)
- S3 (missing index): typically 20–40 min
- S4 (bad deploy): typically 5–15 min (correlate 5xx with rollout history, then `rollout undo`)

Polling "is the symptom gone yet?" is NOT a valid stall signal. The agent may be deep in investigation. Use `-Tail` to see what it is actually doing — only declare a stall if you see repeated re-investigation with no new actions for a long stretch.

## Playwright MCP Usage

Use these Playwright MCP tools throughout:
- `browser_navigate` — go to URLs
- `browser_snapshot` — see page content (use to verify text like "SERVICE DISRUPTION" or "healthy")
- `browser_screenshot` — capture visual state
- `browser_click` — interact with elements if needed

If Playwright MCP is not available, fall back to port-forward via `az aks command invoke` + curl:
```powershell
# Test the API directly via the public ingress (still public — only the cluster API server is private)
Invoke-RestMethod "$storeUrl/api/health"
# Or exec inside an api pod for internal checks:
Invoke-AksCommand -ResourceGroup $rg -ClusterName $aks -Command "kubectl exec -n zava-demo deploy/zava-api -- wget -qO- http://localhost:3001/api/health"
```
