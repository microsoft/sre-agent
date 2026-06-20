# Meter API — Troubleshooting Runbook

## Trigger Keywords
`OOM`, `OutOfMemory`, `memory leak`, `container restart`, `meter-api`, `ca-powergrid-meter`, `SIMULATE_OOM`, `crash`, `killed`

## Scope
The **meter-api** is a .NET 8 Web API service (`ca-powergrid-meter`) that manages meter readings and data. This runbook covers the most common failure mode: the `SIMULATE_OOM` environment variable causing a memory leak that leads to OOM kills and container restarts.

---

## Common Issue: SIMULATE_OOM Causing Memory Leak → OOM Kill

### Symptoms
- Container restarts repeatedly (visible in revision status)
- Memory usage climbs steadily over time until hitting the limit
- HTTP 500/503 errors intermittently (during restart windows)
- Logs show `OutOfMemory`, `OOM`, or `Killed` messages
- .NET garbage collection logs show increasingly large heap sizes
- Health checks fail during restart cycles

### Root Cause
The `SIMULATE_OOM` environment variable is set to `true` on the container app. When enabled, the .NET application allocates memory in a background thread without releasing it, simulating a memory leak. Memory grows until the container exceeds its 1 Gi limit and is OOM-killed by the platform, triggering a restart. The cycle repeats.

---

## Phase 1: Detect — Confirm OOM Events

### 1.1 Check for OOM / Memory Events in Console Logs
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-meter"
| where Log_s contains "OutOfMemory"
    or Log_s contains "OOM"
    or Log_s contains "Killed"
    or Log_s contains "memory"
    or Log_s contains "System.OutOfMemoryException"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 50
```

### 1.2 Check for Container Restart Events
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-meter"
| where Log_s contains "restart"
    or Log_s contains "OOMKilled"
    or Log_s contains "BackOff"
    or Log_s contains "Unhealthy"
    or Log_s contains "killed"
| project TimeGenerated, Log_s, RevisionName_s, Reason_s
| order by TimeGenerated desc
```

### 1.3 Container Restart Count Over Time
```kql
AzureMetrics
| where TimeGenerated > ago(2h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "RestartCount"
| where _ResourceId contains "ca-powergrid-meter"
| summarize MaxRestarts = max(Maximum), AvgRestarts = avg(Average)
by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

### 1.4 Memory Usage Trend
```kql
AzureMetrics
| where TimeGenerated > ago(2h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "WorkingSetBytes" or MetricName == "MemoryPercentage"
| where _ResourceId contains "ca-powergrid-meter"
| summarize AvgValue = avg(Average), MaxValue = max(Maximum) by bin(TimeGenerated, 5m), MetricName
| order by TimeGenerated desc
```

### 1.5 Memory Pressure with Error Correlation
```kql
let memoryEvents = ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-meter"
| where Log_s contains "OutOfMemory" or Log_s contains "OOM"
| summarize OOMCount = count() by bin(TimeGenerated, 5m);
let errorEvents = ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-meter"
| where Log_s contains "500" or Log_s contains "error" or Log_s contains "Error"
| summarize ErrorCount = count() by bin(TimeGenerated, 5m);
memoryEvents
| join kind=fullouter errorEvents on TimeGenerated
| project TimeGenerated, OOMCount = coalesce(OOMCount, 0), ErrorCount = coalesce(ErrorCount, 0)
| order by TimeGenerated desc
```

---

## Phase 2: Diagnose — .NET Specific Diagnostics

### 2.1 Check for SIMULATE_OOM Environment Variable
```bash
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-meter \
  --query "properties.template.containers[0].env" \
  -o table
```

Look for:
```json
{
  "name": "SIMULATE_OOM",
  "value": "true"
}
```

### 2.2 .NET GC and Heap Diagnostics in Logs
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-meter"
| where Log_s contains "GC"
    or Log_s contains "heap"
    or Log_s contains "Heap"
    or Log_s contains "gen0"
    or Log_s contains "gen1"
    or Log_s contains "gen2"
    or Log_s contains "LOH"
    or Log_s contains "finaliz"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 30
```

### 2.3 .NET Exception Stack Traces
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-meter"
| where Log_s contains "Exception" or Log_s contains "StackTrace" or Log_s contains "at "
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 30
```

### 2.4 App Insights Exception Details
```kql
exceptions
| where timestamp > ago(2h)
| where cloud_RoleName contains "meter"
| where type contains "OutOfMemory" or type contains "Memory"
| summarize Count = count(), FirstSeen = min(timestamp), LastSeen = max(timestamp)
by type, problemId, outerMessage
| order by Count desc
```

### 2.5 Container Resource Configuration
```bash
# Check current CPU/Memory allocation
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-meter \
  --query "properties.template.containers[0].resources" \
  -o json
```

---

## Phase 3: Fix — Remove SIMULATE_OOM and Recover

### 3.1 Remove the Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-meter \
  --remove-env-vars SIMULATE_OOM
```

### 3.2 (Optional) Increase Memory Limit if Needed
```bash
# Only if the service legitimately needs more memory
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-meter \
  --cpu 0.5 \
  --memory 2Gi
```

### 3.3 Force Restart if Container is Stuck
```bash
# List revisions to find the active one
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-meter \
  -o table

# Restart the active revision
az containerapp revision restart \
  -g <resourceGroup> \
  -n ca-powergrid-meter \
  --revision <active-revision-name>
```

### 3.4 Verify the Fix
```bash
# Wait 60 seconds for new revision to activate, then:

# Check env vars are clean
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-meter \
  --query "properties.template.containers[0].env" \
  -o table

# Test health endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<meter-api-fqdn>/health

# Test meters endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<meter-api-fqdn>/api/meters
```

---

## Phase 4: Verify — Confirm Recovery

### 4.1 No More Restarts
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(30m)
| where ContainerAppName_s == "ca-powergrid-meter"
| where Log_s contains "restart" or Log_s contains "OOMKilled" or Log_s contains "killed"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

Expected: **No results** (no restarts since fix).

### 4.2 Memory Stable After Fix
```kql
AzureMetrics
| where TimeGenerated > ago(30m)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "WorkingSetBytes"
| where _ResourceId contains "ca-powergrid-meter"
| summarize AvgMemory = avg(Average), MaxMemory = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

Expected: Memory should stabilize at a consistent level, not continuously growing.

### 4.3 Request Success Rate
```kql
requests
| where timestamp > ago(30m)
| where cloud_RoleName contains "meter"
| summarize
    Total = count(),
    Success = countif(resultCode startswith "2"),
    Failed = countif(resultCode startswith "5")
by bin(timestamp, 5m)
| extend SuccessRate = round(100.0 * Success / Total, 2)
| order by timestamp desc
```

---

## .NET Memory Leak Indicators

| Indicator | Normal | Concerning | Critical |
|-----------|--------|------------|----------|
| Working Set | < 200 MB stable | 200-800 MB growing | > 800 MB / near limit |
| GC Gen2 Collections | Infrequent | Increasing | Continuous |
| LOH Allocations | Minimal | Growing | Excessive |
| Restart Count | 0 | 1-2 in 1h | 3+ in 1h |

---

## Other Possible Issues

| Symptom | Possible Cause | Investigation |
|---------|----------------|---------------|
| OOM kills + restarts | `SIMULATE_OOM=true` | Check env vars (this runbook) |
| Slow responses, no OOM | Database query performance | Check Azure SQL DTU usage |
| 500 on POST endpoints | Model validation failure | Check request payload format |
| Connection refused | Container in restart loop | Check restart count and logs |
| Intermittent 503 | Container restarting mid-request | OOM cycle — fix leak first |

---

## Escalation

Escalate if:
- Removing `SIMULATE_OOM` does not stop the memory growth
- Memory continues to grow even without the env var (real memory leak)
- Increasing memory to 2 Gi is still insufficient
- Database connectivity issues compound the problem
- Multiple services are experiencing OOM simultaneously
