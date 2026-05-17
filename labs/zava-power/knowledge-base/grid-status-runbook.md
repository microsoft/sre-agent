# Grid Status API — Troubleshooting Runbook

## Trigger Keywords
`high latency`, `slow response`, `timeout`, `grid-status-api`, `ca-powergrid-grid`, `SIMULATE_DELAY_MS`, `response time`, `delay`

## Scope
The **grid-status-api** is a Node.js/Express service (`ca-powergrid-grid`) that provides real-time grid status and regional power data. This runbook covers the most common failure mode: the `SIMULATE_DELAY_MS` environment variable injecting artificial latency into all requests.

---

## Common Issue: SIMULATE_DELAY_MS Adding Artificial Latency

### Symptoms
- All requests to grid-status-api are abnormally slow (response times in seconds)
- Health checks may pass but with high latency
- Upstream services and portal-web experience timeouts when calling grid-status-api
- No error logs — requests eventually succeed but with added delay
- CPU and memory are normal — the issue is purely latency
- The slowdown aligns with a specific deployment/revision change

### Root Cause
The `SIMULATE_DELAY_MS` environment variable is set on the container app (e.g., `SIMULATE_DELAY_MS=5000`). The Express middleware reads this value and adds an artificial `setTimeout` delay before processing each request. This simulates a bad deployment that introduced a performance regression.

---

## Phase 1: Detect — Confirm High Latency

### 1.1 Check Request Latency in App Insights
```kql
requests
| where timestamp > ago(1h)
| where cloud_RoleName contains "grid"
| summarize
    AvgDuration = avg(duration),
    P50 = percentile(duration, 50),
    P95 = percentile(duration, 95),
    P99 = percentile(duration, 99),
    RequestCount = count()
by bin(timestamp, 5m), name
| order by timestamp desc
```

### 1.2 High Latency Requests in Logs
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-grid"
| where Log_s contains "ms" or Log_s contains "delay" or Log_s contains "latency" or Log_s contains "SIMULATE_DELAY"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 50
```

### 1.3 Timeout Errors from Upstream Services
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "timeout" or Log_s contains "ETIMEDOUT" or Log_s contains "ECONNRESET"
| where Log_s contains "grid" or ContainerAppName_s contains "portal" or ContainerAppName_s contains "outage"
| project TimeGenerated, ContainerAppName_s, Log_s
| order by TimeGenerated desc
```

### 1.4 Confirm via Timed Request
```bash
# Time a request to grid-status-api
time curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime: %{time_total}s\n" \
  https://<grid-status-api-fqdn>/api/grid/status

# Healthy: ~100-300ms
# With SIMULATE_DELAY_MS=5000: ~5+ seconds
```

---

## Phase 2: Diagnose — Correlate with Deployment

### 2.1 Check Environment Variables
```bash
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --query "properties.template.containers[0].env" \
  -o table
```

Look for:
```json
{
  "name": "SIMULATE_DELAY_MS",
  "value": "5000"
}
```

### 2.2 List Revisions and Identify Bad Deployment
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  -o table
```

### 2.3 Correlate Deployment Time with Latency Onset
```kql
// Get deployment events
let deployEvents = ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-powergrid-grid"
| where Log_s contains "revision" or Log_s contains "deploy" or Log_s contains "Pulling" or Log_s contains "Started"
| project DeployTime = TimeGenerated, Log_s, RevisionName_s;
// Get latency trend
let latencyTrend = requests
| where timestamp > ago(24h)
| where cloud_RoleName contains "grid"
| summarize AvgDuration = avg(duration), P95 = percentile(duration, 95) by bin(timestamp, 10m);
// Show both for correlation
deployEvents
| order by DeployTime desc
```

### 2.4 Compare Revisions — Before and After
```kql
// Latency by revision
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-powergrid-grid"
| where Log_s matches regex @"\d+ms"
| extend RevisionShort = tostring(split(RevisionName_s, "--")[1])
| summarize LogCount = count() by RevisionShort, bin(TimeGenerated, 15m)
| order by TimeGenerated desc
```

### 2.5 Verify It's Not a Real Performance Issue
```kql
// CPU and memory are normal during high latency → artificial delay
AzureMetrics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName in ("UsageNanoCores", "WorkingSetBytes")
| where _ResourceId contains "ca-powergrid-grid"
| summarize AvgValue = avg(Average), MaxValue = max(Maximum) by bin(TimeGenerated, 5m), MetricName
| order by TimeGenerated desc
```

---

## Phase 3: Fix — Remove SIMULATE_DELAY_MS or Rollback

### Option A: Remove the Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --remove-env-vars SIMULATE_DELAY_MS
```

### Option B: Rollback to Previous Revision

Use this if the bad deployment also included other problematic changes.

```bash
# 1. List revisions to find the last known good revision
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  -o table

# 2. Activate the previous (good) revision
az containerapp revision activate \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --revision <previous-good-revision>

# 3. Route 100% traffic to the good revision
az containerapp ingress traffic set \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --revision-weight <previous-good-revision>=100

# 4. Deactivate the bad revision
az containerapp revision deactivate \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --revision <bad-revision>
```

### 3.1 Verify the Fix
```bash
# Wait 30-60 seconds, then:

# Time a request — should be fast now
time curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime: %{time_total}s\n" \
  https://<grid-status-api-fqdn>/api/grid/status

# Check env vars are clean
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --query "properties.template.containers[0].env" \
  -o table
```

---

## Phase 4: Verify — Confirm Latency is Normal

### 4.1 Latency After Fix
```kql
requests
| where timestamp > ago(30m)
| where cloud_RoleName contains "grid"
| summarize
    AvgDuration = avg(duration),
    P95 = percentile(duration, 95),
    RequestCount = count()
by bin(timestamp, 5m)
| order by timestamp desc
```

Expected: Avg duration < 500ms, P95 < 1s.

### 4.2 No More Timeout Errors Upstream
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(30m)
| where Log_s contains "timeout" or Log_s contains "ETIMEDOUT"
| where Log_s contains "grid"
| summarize Count = count()
```

Expected: Count = 0.

### 4.3 Active Revision Confirmation
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --query "[?properties.active==\`true\`].{Name:name, Created:properties.createdTime, TrafficWeight:properties.trafficWeight}" \
  -o table
```

---

## Latency Thresholds Reference

| Metric | Normal | Warning | Critical |
|--------|--------|---------|----------|
| Avg Response Time | < 300ms | 300ms - 2s | > 2s |
| P95 Response Time | < 500ms | 500ms - 5s | > 5s |
| P99 Response Time | < 1s | 1s - 10s | > 10s |
| Timeout Rate | 0% | < 1% | > 1% |

---

## Other Possible Issues

| Symptom | Possible Cause | Investigation |
|---------|----------------|---------------|
| Uniform high latency on all endpoints | `SIMULATE_DELAY_MS` set | Check env vars (this runbook) |
| Slow on specific endpoints only | Database query performance | Check Azure SQL metrics |
| Intermittent timeouts | Network connectivity | Check Container App Environment logs |
| Increasing latency over time | Memory leak or CPU saturation | Check resource metrics |
| 502/503 after long wait | Upstream timeout exceeded | Check ingress timeout settings |

---

## Escalation

Escalate if:
- Removing `SIMULATE_DELAY_MS` does not resolve the latency
- Rollback to previous revision still shows high latency
- Latency is caused by database or downstream dependency issues
- Portal-web is completely non-functional due to grid-status-api timeouts
