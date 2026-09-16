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
# The SRE Agent uses the built-in RunKubectl* system tools; this helper is for human operators.
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

When observing or prompting the SRE Agent, use its built-in
`RunKubectlReadCommand` and `RunKubectlWriteCommand` tools for Kubernetes.

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
6. Both database scenarios share `postgres-unreachable`, with response-plan merge
   disabled. Wait for Azure Monitor's **monitor condition** to become `Resolved`
   before Scenario 2. Alert state (`New`, `Acknowledged`, `Closed`) is separate:
   closing an alert does not reset a still-fired condition. The agent should close
   only its owned alert after recovery when its tools permit that operation, or
   report closure blocked and let auto-mitigation clear the condition. Diagnose
   each fault from ARM state (`Stopped` versus `Ready` but unreachable), not the
   error text alone.

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

> **Heads-up if you just ran Scenario 1:** both DB scenarios share
> `postgres-unreachable`. Wait for `monitorCondition == Resolved` before injecting
> the network fault. Closing the previous alert alone does not reset its condition,
> and a still-fired condition can prevent a fresh investigation.

```powershell
.\.github\skills\running-demo\scripts\break-network.ps1
```
Wait 30 seconds.

### Step 3: Show the break
1. Navigate to `$storeUrl` — should show "SERVICE DISRUPTION" with ETIMEDOUT errors
2. Take screenshot — note: error says "timeout" not "connection refused" (server is up but unreachable)

### Step 4: Watch the agent
1. Check SRE Agent portal for investigation
2. Agent needs to find the K8s NetworkPolicy with `RunKubectlReadCommand` using `kubectl get networkpolicy -n zava-demo -o yaml`, then remove it with `RunKubectlWriteCommand` using `kubectl delete networkpolicy database-tier-isolation -n zava-demo` - this is harder than Scenario 1 and may take longer
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
# Drops idx_products_category_name AND idx_products_category so neither existing
# category index can mask the missing-index scenario. Also rolls the
# api deployment to clear PG plan cache + restart the OTel exporter, then
# verifies AppRequests telemetry is flowing before launching the load Job.
# Variants are seeded automatically on first deploy (50 originals + 120,000
# size/color/edition variants from seed.js), so this is a single command.
.\.github\skills\running-demo\scripts\break-db-perf.ps1
```
If the telemetry query fails, resolve the query or access error before retrying;
failure is not evidence of zero traffic. If the query succeeds with no recent
AppRequests, verify application instrumentation and ingestion. Use
`-SkipTelemetryCheck` only when an empty workspace is intentional.

### Step 3: Show degraded performance
1. Navigate to `$storeUrl/api/diagnostics`
2. Confirm both category indexes are absent and `seq_scan` increases.
   `index_usage_pct` is cumulative and need not fall to zero for this run.
3. Take screenshot
4. (`break-db-perf.ps1` already launched a 15-min in-cluster Kubernetes Job (`zava-cat-load` in the `zava-demo` namespace) that hammers `/api/products/category/<X>` over the cluster-internal Service DNS. This pushes real traffic past the alert's 30ms threshold — the 1Hz `__probe` is excluded by the alert KQL. The Job auto-cleans 60s after completion via `ttlSecondsAfterFinished`; `fix-db-perf.ps1` also deletes it explicitly. Run with `-NoLoad` to skip.)

### Step 4: Watch agent
1. Monitor SRE Agent portal - it should detect slow response times via App Insights, inspect the query with `QueryZavaPostgres`, and run the bounded category-index repair through `RepairZavaPostgresIndexes`.
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
   Confirm the affected category query returns to baseline under comparable load.
   Recheck its full query shape, including ordering and pagination. A rising index
   scan count or the load Job ending does not by itself prove performance recovery.
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
A failed telemetry query stops the script before fault injection. Resolve query
errors separately from a successful query showing no recent requests; do not
bypass the check merely because a query failed.

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

## Scenario 5: Compound Independent Faults

This proof-of-concept scenario overlaps Scenario 3 and Scenario 4 by 90 seconds.
It demonstrates how to compare two nearby alerts before deciding whether they share
a cause.

### Step 1: Confirm healthy state
1. Navigate to `$storeUrl` and `$storeUrl/api/health`
2. Confirm products load and the database is connected

### Step 2: Break both paths
```powershell
.\.github\skills\running-demo\scripts\break-compound.ps1
```
The script drops both category indexes, starts the sustained category load,
waits 90 seconds, then deploys `FAULT_INJECT=500`.

### Step 3: Verify the overlap
1. `$storeUrl/api/products` returns HTTP 500 while `/api/health` remains healthy.
2. Query `/api/diagnostics`; both category indexes are absent and product scans are sequential.
3. Confirm the `zava-cat-load` Job is active through `Invoke-AksCommand`.
4. Expect both `Zava-products-query-slow` and `Zava-http-5xx-errors` within 5-10 minutes.

### Step 4: Review the investigation
Confirm that the investigation compares the available evidence:
- 5xx failures are app-local (`localhost:3001`) and correlate with the rollout.
- PostgreSQL CPU/latency rises, but its slow queries succeed and create no failed PG dependencies.
- `Zava-db-cpu-saturation` is present but disabled.

Alert timestamps identify temporal overlap, not causation. Use request, dependency,
deployment, and PostgreSQL telemetry to establish whether a mechanism is shared.

This scenario is intentionally narrow. It demonstrates one correlation approach and
does not represent every incident pattern or guarantee a particular model outcome.

### Step 5: Cleanup
Let the SRE Agent remediate during a demo. For post-demo cleanup or test teardown:
```powershell
.\.github\skills\running-demo\scripts\fix-compound.ps1
```
Verify `/api/products` returns 200, both indexes exist, and the load Job is gone.

## Chat demo: interrogate the hub firewall (network device)

No break needed — this shows the agent treating the **hub Azure Firewall** as a queryable "network device" in the hub-and-spoke topology.

1. Open the agent chat (`$agentUrl`) and ask:
   > "Inspect the hub Azure Firewall: summarize its egress allow-list (rule collections), and query the `AZFW*` Log Analytics tables for anything denied for the agent subnet in the last hour."
2. Expect the agent to read the firewall policy over ARM (`az network firewall policy ...`, covered by its Reader role) and run KQL against `AZFWApplicationRule` / `AZFWNetworkRule`.
3. Optional follow-up — *"Is the firewall in the path between the app and PostgreSQL?"* The correct answer is **no**: it gates only the agent's own egress; the app↔PG path is governed by the platform-spoke NSG and the in-cluster Kubernetes NetworkPolicy. This confirms the agent has the topology boundary right.

This is a read/diagnostic demonstration, not a break/fix — the firewall gates the agent's *own* egress, so breaking it would disable the agent itself.

## Watching the SRE Agent

In a separate shell, view investigation progress through the data-plane API:
```powershell
.\scripts\watch-agent.ps1                              # list all threads
.\scripts\watch-agent.ps1 -Show -Title slow            # details for latest matching incident
.\scripts\watch-agent.ps1 -Tail -Title slow            # poll for new messages until Resolved/Closed/Mitigated
```

Investigation time varies by scenario and environment. Use `-Tail` to follow progress
before deciding whether manual cleanup is needed.

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
