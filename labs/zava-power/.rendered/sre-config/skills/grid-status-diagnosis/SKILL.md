---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: grid-status-diagnosis
description: Diagnose and fix grid-status-api performance regressions including high latency, slow /regions responses, and Node.js event loop blocking. Use when response times exceed 1 second.
---

# grid-status-diagnosis

## Scope
The **grid-status-api** is a Node.js/Express service (`ca-powergrid-grid`) that provides real-time grid status and regional power data. This skill guides you through diagnosing any performance regression — from detecting latency spikes, through identifying whether the cause is code, configuration, or infrastructure, to applying the right fix.

---

## Phase 1: DETECT — Measure the Latency

### 1.1 Measure Current Response Times
```bash
# Time a request to grid-status-api
curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime: %{time_total}s\n" \
  https://<grid-status-api-fqdn>/api/grid/status

curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime: %{time_total}s\n" \
  https://<grid-status-api-fqdn>/health
```

Compare response times. Are ALL endpoints slow, or only specific ones? This distinction matters in Phase 2.

### 1.2 App Insights Latency Percentiles
```kql
requests
| where timestamp > ago(2h)
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

Establish: what is the current latency, and when did it change from baseline? Normal baseline is P50 < 200ms, P95 < 500ms.

### 1.3 Latency Trend — Find the Inflection Point
```kql
requests
| where timestamp > ago(12h)
| where cloud_RoleName contains "grid"
| summarize
    P50 = percentile(duration, 50),
    P95 = percentile(duration, 95)
by bin(timestamp, 10m)
| order by timestamp asc
```

Note the exact time latency spiked. You'll compare this to deployments and other events in Phase 2.

### 1.4 Upstream Impact — Timeouts from Callers
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where Log_s contains "timeout" or Log_s contains "ETIMEDOUT" or Log_s contains "ECONNRESET"
| where Log_s contains "grid" or ContainerAppName_s contains "portal" or ContainerAppName_s contains "outage"
| project TimeGenerated, ContainerAppName_s, Log_s
| order by TimeGenerated desc
```

### 1.5 Console Log Errors
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-grid"
| where Log_s contains "Error"
    or Log_s contains "error"
    or Log_s contains "WARN"
    or Log_s contains "timeout"
    or Log_s contains "FATAL"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 50
```

---

## Phase 2: INVESTIGATE — Find What's Causing the Latency

### 2.1 Check CPU and Memory — Is It a Resource Issue?
```kql
AzureMetrics
| where TimeGenerated > ago(2h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName in ("UsageNanoCores", "WorkingSetBytes")
| where _ResourceId contains "ca-powergrid-grid"
| summarize AvgValue = avg(Average), MaxValue = max(Maximum) by bin(TimeGenerated, 5m), MetricName
| order by TimeGenerated desc
```

- **High CPU + high latency** → CPU-bound operation blocking the Node.js event loop (e.g., synchronous computation, tight loop)
- **Normal CPU + high latency** → Not a CPU problem; likely an artificial delay, slow dependency, or connection pool exhaustion
- **High memory** → Possible memory pressure causing GC pauses

### 2.2 Check Environment Variables
```bash
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --query "properties.template.containers[0].env" \
  -o table
```

Look for any env var that could inject delays, alter timeouts, or change service behavior.

### 2.3 Correlate Latency Onset with Deployments
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-powergrid-grid"
| where Log_s contains "revision" or Log_s contains "Pulling" or Log_s contains "Started" or Log_s contains "created"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

Did the latency spike start at the same time as a new revision? If so, the deployment is the likely cause.

### 2.4 List Revisions — Compare Current with Previous
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  -o table
```

### 2.5 Check Dependency Performance
```kql
dependencies
| where timestamp > ago(1h)
| where cloud_RoleName contains "grid"
| summarize
    AvgDuration = avg(duration),
    P95 = percentile(duration, 95),
    FailureCount = countif(success == false)
by target, type
| order by AvgDuration desc
```

Slow dependencies (database, downstream APIs) can cause the service to appear slow even if its own code is fast.

### 2.6 Look for Event Loop Blocking Indicators
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-grid"
| where Log_s contains "event loop"
    or Log_s contains "blocked"
    or Log_s contains "CPU"
    or Log_s contains "sync"
    or Log_s contains "intensive"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

### 2.7 Check for Connection Pool Issues
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-grid"
| where Log_s contains "pool"
    or Log_s contains "connection"
    or Log_s contains "ECONNREFUSED"
    or Log_s contains "ENOTFOUND"
    or Log_s contains "socket hang up"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

---

## Phase 3: ROOT CAUSE — Interpret Findings

| Finding | Likely Root Cause | Next Step |
|---------|-------------------|-----------|
| All endpoints uniformly slow, normal CPU/memory | Artificial delay injected via env var or middleware | Check env vars, remove the offending setting |
| Latency spike aligns exactly with deployment | Bad deployment introduced slow code or config | Rollback to previous revision |
| High CPU correlating with latency | CPU-bound synchronous operation blocking event loop | Rollback or fix blocking code |
| Slow on specific endpoints only, others fast | Endpoint-specific issue (slow query, slow dependency) | Check dependency latency for those endpoints |
| Normal latency in App Insights but callers report timeouts | Network-level issue or ingress timeout misconfiguration | Check ingress settings and Container App networking |
| Dependency calls show high latency | Downstream dependency is slow, not this service | Investigate the slow dependency |
| Memory growing + increasing GC pauses | Node.js memory leak causing GC-induced latency | Check for memory leaks, restart or increase memory |

### Latency Thresholds

| Metric | Normal | Warning | Critical |
|--------|--------|---------|----------|
| Avg Response Time | < 300ms | 300ms - 2s | > 2s |
| P95 Response Time | < 500ms | 500ms - 5s | > 5s |
| P99 Response Time | < 1s | 1s - 10s | > 10s |
| Timeout Rate | 0% | < 1% | > 1% |

---

## Phase 4: FIX — Apply the Appropriate Remediation

Choose based on Phase 3 findings. Do NOT guess — match the fix to the diagnosed cause.

### Option A: Remove a Problematic Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --remove-env-vars <ENV_VAR_NAME>
```

### Option B: Rollback to Previous Revision
Use the `deployment-rollback` skill for a safe rollback procedure.

### Option C: Scale Out
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --min-replicas 2 \
  --max-replicas 5
```

### Verify the Fix
```bash
# Wait 30-60 seconds, then time a request
curl -s -o /dev/null -w "HTTP Status: %{http_code}\nTime: %{time_total}s\n" \
  https://<grid-status-api-fqdn>/api/grid/status
```

```kql
// Confirm latency has returned to baseline
requests
| where timestamp > ago(15m)
| where cloud_RoleName contains "grid"
| summarize
    AvgDuration = avg(duration),
    P95 = percentile(duration, 95),
    RequestCount = count()
by bin(timestamp, 5m)
| order by timestamp desc
```

```kql
// Confirm no more upstream timeouts
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(15m)
| where Log_s contains "timeout" or Log_s contains "ETIMEDOUT"
| where Log_s contains "grid"
| summarize Count = count()
```

```bash
# Confirm active revision
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-grid \
  --query "[?properties.active==\`true\`].{Name:name, Created:properties.createdTime, TrafficWeight:properties.trafficWeight}" \
  -o table
```

If latency persists after fix, re-enter Phase 2 with fresh data.

---

## Escalation

Escalate if:
- Root cause cannot be determined from available metrics and logs
- The fix does not return latency to normal within 5 minutes
- Latency is caused by infrastructure or networking outside your control
- Multiple downstream services are affected (systemic issue)
