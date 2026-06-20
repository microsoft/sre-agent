# HTTP 500 Error Investigation Runbook

## Trigger Keywords
`500 error`, `internal server error`, `HTTP 500`, `server error`, `application error`, `unresponsive`

## Scope
Azure Container Apps endpoints returning HTTP 500 errors. Logs stored in Log Analytics Workspace.

## Valid Azure Monitor Metric Names for Container Apps
**IMPORTANT: Use ONLY these metric names with `az monitor metrics list`:**
- `UsageNanoCores` — CPU usage (NOT CpuUsage, NOT CPUUsage)
- `WorkingSetBytes` — Memory usage (NOT MemoryUsage, NOT MemoryWorkingSet)
- `Requests` — HTTP request count
- `RestartCount` — Container restarts (OOM indicator)
- `Replicas` — Active replica count
- `CpuPercentage` — CPU percentage
- `MemoryPercentage` — Memory percentage

## Container App Logs CLI
**Use `az containerapp logs show` with `--tail` (NOT `--since`):**
```bash
az containerapp logs show -g <resourceGroup> -n <appName> --tail 300
az containerapp logs show -g <resourceGroup> -n <appName> --tail 300 --format text
```

---

## Phase 1: CPU and Memory Metrics (Check First)

### 1.1 CPU Metrics (App Insights / Azure Monitor)
```kql
performanceCounters
| where timestamp > ago(1h)
| where name == "% Processor Time" or name contains "CPU"
| summarize AvgCPU = avg(value), MaxCPU = max(value) by bin(timestamp, 5m)
| order by timestamp desc
```

### 1.2 Memory Usage Over Time
```kql
performanceCounters
| where timestamp > ago(1h)
| where name contains "Memory" or name == "Available Bytes" or name == "Private Bytes"
| summarize AvgMemory = avg(value), MaxMemory = max(value) by bin(timestamp, 5m), name
| order by timestamp desc
```

### 1.3 Container App Metrics via Azure Monitor
```kql
AzureMetrics
| where TimeGenerated > ago(1h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName in ("UsageNanoCores", "WorkingSetBytes", "Requests", "RestartCount")
| summarize AvgValue = avg(Average), MaxValue = max(Maximum) by bin(TimeGenerated, 5m), MetricName
| order by TimeGenerated desc
```

### 1.4 Get Metrics via Azure CLI
```bash
# List available metrics for container app
az monitor metrics list-definitions --resource <resourceId>

# Get CPU usage metrics (last 1 hour)
az monitor metrics list --resource <resourceId> --metric "UsageNanoCores" --interval PT5M --start-time $(date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ") --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get Memory usage metrics (last 1 hour)
az monitor metrics list --resource <resourceId> --metric "WorkingSetBytes" --interval PT5M --start-time $(date -u -d '1 hour ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ") --end-time $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Example with full resource ID:
az monitor metrics list --resource "/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-grubify-app/providers/Microsoft.App/containerApps/ca-grubify-api" --metric "UsageNanoCores" --interval PT5M
```

### 1.5 Memory Pressure Indicators
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "OutOfMemory" 
    or Log_s contains "OOM" 
    or Log_s contains "memory pressure"
    or Log_s contains "GC"
    or Log_s contains "heap"
| project TimeGenerated, Log_s, ContainerName_s
| order by TimeGenerated desc
```

### 1.6 Detect High CPU Correlation with Errors
```kql
let highCpuTimes = performanceCounters
| where timestamp > ago(1h)
| where name contains "CPU"
| where value > 80
| summarize by bin(timestamp, 5m);
requests
| where timestamp > ago(1h)
| where resultCode startswith "5"
| summarize ErrorCount = count() by bin(timestamp, 5m)
| join kind=inner highCpuTimes on timestamp
| order by timestamp desc
```

### Resource Thresholds Reference
| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| CPU % | > 70% sustained | > 90% sustained | Scale out replicas |
| Memory % | > 75% sustained | > 90% sustained | Scale up memory or fix leak |
| Memory Working Set | Steadily increasing | Near limit | Investigate memory leak |

---

## Phase 2: Initial Triage

### 2.1 Get Container App Details
```bash
# Show container app configuration
az containerapp show -g <resourceGroup> -n <appName> --subscription <subId> --output json

# Example:
az containerapp show -g rg-grubify-app -n ca-grubify-api --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 --output json
```

### 2.2 Get Current Revision Logs
```bash
# Get recent logs from active revision (last 300 lines)
az containerapp logs show -g <resourceGroup> -n <appName> --subscription <subId> --revision <revisionId> --tail 300

# Example:
az containerapp logs show -g rg-octopets-nov9 -n octopetsapi --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 --revision octopetsapi--0000003 --tail 300

# If command fails, retry with --format text:
az containerapp logs show -g rg-octopets-nov9 -n octopetsapi --subscription cbf44432-7f45-4906-a85d-d2b14a1e8328 --revision octopetsapi--0000003 --tail 300 --format text
```

### 2.3 Quick Error Count (KQL)
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "error" or Log_s contains "exception" or Log_s contains "500"
| summarize ErrorCount = count() by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

---

## Phase 3: Identify Error Patterns

### 3.1 Top Errors by Message
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "error" or Log_s contains "exception"
| extend ErrorMessage = extract("(Exception|Error|Failed|Fault).*", 0, Log_s)
| summarize Count = count(), 
    FirstSeen = min(TimeGenerated), 
    LastSeen = max(TimeGenerated)
by ErrorMessage
| order by Count desc
| take 10
```

### 3.2 Failed HTTP Requests (App Insights)
```kql
requests
| where timestamp > ago(1h)
| where resultCode startswith "5"
| summarize FailedCount = count(), 
    AvgDuration = avg(duration),
    P95Duration = percentile(duration, 95)
by name, resultCode, url
| order by FailedCount desc
| take 20
```

### 3.3 Error Rate Over Time
```kql
requests
| where timestamp > ago(1h)
| summarize 
    Total = count(),
    Failed = countif(resultCode startswith "5"),
    ErrorRate = round(100.0 * countif(resultCode startswith "5") / count(), 2)
by bin(timestamp, 5m)
| order by timestamp desc
```

---

## Phase 4: Exception Details

### 4.1 Top Exceptions with Stack Traces
```kql
exceptions
| where timestamp > ago(1h)
| summarize Count = count(), 
    FirstSeen = min(timestamp),
    LastSeen = max(timestamp)
by type, problemId, outerMessage
| order by Count desc
| take 10
```

### 4.2 Full Exception Details (Sample)
```kql
exceptions
| where timestamp > ago(1h)
| project timestamp, type, outerMessage, innermostMessage, details, operation_Id
| order by timestamp desc
| take 5
```

### 4.3 Trace Correlation for Specific Error
```kql
// Replace <operation_Id> with value from exceptions query
let targetOpId = "<operation_Id>";
union requests, dependencies, traces, exceptions
| where operation_Id == targetOpId
| project timestamp, itemType, name, resultCode, duration, message, outerMessage
| order by timestamp asc
```

---

## Phase 5: Dependency Health Check

### 5.1 Failing Dependencies
```kql
dependencies
| where timestamp > ago(1h)
| where success == false
| summarize FailureCount = count(), 
    AvgDuration = avg(duration)
by type, target, resultCode, name
| order by FailureCount desc
| take 10
```

### 5.2 Dependency Latency Spikes
```kql
dependencies
| where timestamp > ago(1h)
| summarize 
    AvgDuration = avg(duration),
    P95Duration = percentile(duration, 95),
    P99Duration = percentile(duration, 99),
    CallCount = count()
by bin(timestamp, 5m), type, target
| where P95Duration > 1000  // Flag slow dependencies (>1s)
| order by timestamp desc
```

### 5.3 Database Connection Issues
```kql
dependencies
| where timestamp > ago(1h)
| where type == "SQL" or type contains "database" or type contains "cosmos"
| summarize 
    Total = count(),
    Failed = countif(success == false),
    AvgDuration = avg(duration)
by target, name
| extend FailRate = round(100.0 * Failed / Total, 2)
| order by FailRate desc
```

---

## Phase 6: Container Health

### 6.1 Container Restarts/Crashes
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "restart" or Log_s contains "crash" or Log_s contains "OOMKilled"
| project TimeGenerated, Log_s, ContainerName_s, RevisionName_s
| order by TimeGenerated desc
```

### 6.2 Resource Exhaustion (OOM)
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "OutOfMemory" or Log_s contains "OOM" or Log_s contains "memory"
| project TimeGenerated, Log_s, ContainerName_s
| order by TimeGenerated desc
```

### 6.3 Check Managed Environment Health
```bash
az containerapp env show --ids <resourceId> --subscription <subId>
```

---

## Phase 7: Deployment Correlation

### 7.1 Recent Deployments
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where Log_s contains "revision" or Log_s contains "deploy"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

### 7.2 Errors After Deployment (Timeline)
```kql
let deployTime = datetime(2025-12-19T10:00:00Z);  // Replace with actual deploy time
ContainerAppConsoleLogs_CL
| where TimeGenerated between (deployTime .. (deployTime + 2h))
| where Log_s contains "error" or Log_s contains "exception"
| summarize ErrorCount = count() by bin(TimeGenerated, 5m)
| order by TimeGenerated asc
```

---

## Phase 8: User Impact Assessment

### 8.1 Affected Users Count
```kql
requests
| where timestamp > ago(1h)
| where resultCode startswith "5"
| summarize 
    AffectedUsers = dcount(user_Id),
    AffectedSessions = dcount(session_Id),
    FailedRequests = count()
```

### 8.2 Geographic Distribution of Errors
```kql
requests
| where timestamp > ago(1h)
| where resultCode startswith "5"
| summarize ErrorCount = count() by client_CountryOrRegion
| order by ErrorCount desc
| take 10
```

---

## Quick Diagnosis Checklist

| Check | Phase | What to Look For |
|-------|-------|------------------|
| CPU/Memory spikes | Phase 1 | High CPU or memory = resource exhaustion |
| Error spike timing | Phase 3.3 | Sudden spike = deployment or external trigger |
| Exception type | Phase 4.1 | NullRef = code bug, Timeout = dependency |
| Dependency failures | Phase 5.1 | DB/API connection issues |
| Container restarts | Phase 6.1 | OOM = scale up or memory leak |
| Recent deploy | Phase 7.1 | Errors started after deploy = rollback candidate |

---

## Common Root Causes

| Symptom | Likely Cause | Next Step |
|---------|--------------|-----------|
| High CPU + errors | Resource exhaustion | Scale out replicas |
| High Memory + OOM | Memory leak or undersized | Scale up memory, investigate leak |
| Sudden spike after deploy | Bad code release | Rollback to previous revision |
| Dependency timeouts | Database/API overload | Check dependency health |
| Connection refused | Service down or network issue | Check target service status |
| NullReferenceException | Code bug | Trace specific request, review code |

---

## Escalation Criteria

Escalate immediately if:
- Error rate > 50% for 5+ minutes
- All requests failing (100% error rate)
- OOM kills happening repeatedly
- Database connection pool exhausted
- Multiple services affected simultaneously

---

## Phase 9: Send Analysis Email

After completing investigation, send an email summary to the incident stakeholders.

**Send to:** sre-team@contoso.com

### Email Structure

**Subject:** `[Incident {incidentID}] HTTP 500 Error Analysis - {appName}`

**Body should include:**

1. **Incident Summary**
   - App name, environment, incident start time (UTC)
   - Current error rate and affected user count

2. **Key Findings**
   - CPU/Memory status at time of incident
   - Top error messages with counts
   - Suspected root cause
   - Timeline of when errors started

3. **Evidence**
   - Resource metrics (CPU/Memory charts or values)
   - Top 3 exception types with sample stack traces
   - Failing endpoints with request counts
   - Dependency failures if applicable
   - Include KQL queries used (for reproducibility)

4. **Recommended Actions**
   - Immediate: rollback, scale, restart
   - Follow-up: code fix, config change, monitoring

5. **Links**
   - Incident link (PagerDuty/ServiceNow)
   - Log Analytics workspace query link
   - GitHub issue (if created)

### Sample Email Template

```
Subject: [Incident INC0012345] HTTP 500 Error Analysis - ca-grubify-api

## Summary
- **App:** ca-grubify-api (Production)
- **Incident Start:** 2025-12-19T14:30:00Z
- **Error Rate:** 45% (was 0.1% before incident)
- **Affected Users:** 1,247

## Resource Status
- **CPU:** 92% avg (Critical - exceeded 90% threshold)
- **Memory:** 78% avg (Warning - approaching limit)

## Key Findings
- **Root Cause:** CPU saturation causing request timeouts
- **Timeline:** CPU spike at 14:25 UTC, errors started at 14:28 UTC
- **Top Exception:** TimeoutException (1,832 occurrences)

## Evidence
### Resource Metrics
| Time (UTC) | CPU % | Memory % |
|------------|-------|----------|
| 14:25 | 45% | 72% |
| 14:30 | 92% | 78% |
| 14:35 | 95% | 81% |

### Top Errors (Last Hour)
| Error | Count | First Seen |
|-------|-------|------------|
| TimeoutException | 1,832 | 14:28 UTC |
| SqlException | 445 | 14:30 UTC |

## Recommended Actions
1. **Immediate:** Scale out to 5 replicas (currently 2)
2. **Follow-up:** Investigate CPU-intensive operation in OrderService.cs

## Links
- [PagerDuty Incident](https://pagerduty.com/incidents/INC0012345)
- [Log Analytics Query](https://portal.azure.com/...)
- [GitHub Issue #456](https://github.com/org/repo/issues/456)
```
