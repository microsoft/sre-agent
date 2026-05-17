# meter-api-diagnosis

## Scope
The **meter-api** is a .NET 8 Web API service (`{{AZ_APP_PREFIX}}-meter`) that manages meter readings and data. This skill guides you through a systematic investigation of container restarts, memory pressure, OOM kills, and other .NET-specific failures.

---

## Phase 1: DETECT — Check Health and Container Stability

### 1.1 Check Service Health
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" https://<meter-api-fqdn>/health
curl -s -w "\nHTTP Status: %{http_code}\n" https://<meter-api-fqdn>/api/meters
```

### 1.2 Check Container Restart Count
```kql
AzureMetrics
| where TimeGenerated > ago(4h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "RestartCount"
| where _ResourceId contains "{{AZ_APP_PREFIX}}-meter"
| summarize MaxRestarts = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

A climbing restart count indicates crash-looping. Note the pattern — constant restarts vs. periodic restarts.

### 1.3 Memory Usage Trend
```kql
AzureMetrics
| where TimeGenerated > ago(4h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "WorkingSetBytes" or MetricName == "MemoryPercentage"
| where _ResourceId contains "{{AZ_APP_PREFIX}}-meter"
| summarize AvgValue = avg(Average), MaxValue = max(Maximum) by bin(TimeGenerated, 5m), MetricName
| order by TimeGenerated asc
```

Look for the shape: **flat** (healthy), **sawtooth** (OOM crash + restart cycle), or **steady climb** (leak without crash yet).

### 1.4 Check for System-Level Events (OOM kills, restarts, failures)
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "restart"
    or Log_s contains "OOMKilled"
    or Log_s contains "BackOff"
    or Log_s contains "Unhealthy"
    or Log_s contains "killed"
    or Log_s contains "exit"
    or Log_s contains "Failed"
| project TimeGenerated, Log_s, RevisionName_s, Reason_s
| order by TimeGenerated desc
```

### 1.5 Console Log Errors — Get the Full Picture
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "Error"
    or Log_s contains "Exception"
    or Log_s contains "OutOfMemory"
    or Log_s contains "Killed"
    or Log_s contains "FATAL"
    or Log_s contains "Unhandled"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 50
```

---

## Phase 2: INVESTIGATE — Diagnose the .NET Failure

### 2.1 Look for OOM Indicators
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "OutOfMemory"
    or Log_s contains "System.OutOfMemoryException"
    or Log_s contains "OOM"
    or Log_s has_any ("GC", "heap", "Heap", "gen0", "gen1", "gen2", "LOH", "finaliz")
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 30
```

If OOM-related entries appear, proceed to 2.2. If not, check 2.3 for other exception types.

### 2.2 Correlate Memory Growth with Restart Events
```kql
let memoryEvents = ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(4h)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "OutOfMemory" or Log_s contains "OOM" or Log_s contains "memory"
| summarize OOMCount = count() by bin(TimeGenerated, 5m);
let errorEvents = ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(4h)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "500" or Log_s contains "Error" or Log_s contains "Exception"
| summarize ErrorCount = count() by bin(TimeGenerated, 5m);
memoryEvents
| join kind=fullouter errorEvents on TimeGenerated
| project TimeGenerated, OOMCount = coalesce(OOMCount, 0), ErrorCount = coalesce(ErrorCount, 0)
| order by TimeGenerated asc
```

### 2.3 .NET Exception Stack Traces
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "Exception" or Log_s contains "StackTrace" or Log_s contains "at " or Log_s contains "Unhandled"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 50
```

Read the stack trace: what exception type, what class/method, what line? This tells you whether it's a memory issue, a dependency failure, or a code bug.

### 2.4 Check Environment Variables for Suspicious Settings
```bash
az containerapp show \
  -g <resourceGroup> \
  -n {{AZ_APP_PREFIX}}-meter \
  --query "properties.template.containers[0].env" \
  -o table
```

Look for any env vars that could alter memory behavior, enable debug/simulation modes, or misconfigure the runtime.

### 2.5 Check Container Resource Limits
```bash
az containerapp show \
  -g <resourceGroup> \
  -n {{AZ_APP_PREFIX}}-meter \
  --query "properties.template.containers[0].resources" \
  -o json
```

Is the memory limit sufficient for this workload? A limit that's too low will cause OOM kills even under normal load.

### 2.6 Check for Recent Deployments
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "revision" or Log_s contains "Pulling" or Log_s contains "Started" or Log_s contains "created"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

Did the restarts start after a deployment? Compare error onset time with deployment time.

### 2.7 App Insights Exception Breakdown
```kql
exceptions
| where timestamp > ago(2h)
| where cloud_RoleName contains "meter"
| summarize Count = count(), FirstSeen = min(timestamp), LastSeen = max(timestamp)
by type, problemId, outerMessage
| order by Count desc
```

### 2.8 Dependency Health (database, downstream services)
```kql
dependencies
| where timestamp > ago(1h)
| where cloud_RoleName contains "meter"
| where success == false
| summarize FailureCount = count() by target, type, resultCode
| order by FailureCount desc
```

---

## Phase 3: ROOT CAUSE — Interpret Findings

| Finding | Likely Root Cause | Next Step |
|---------|-------------------|-----------|
| Memory sawtooth pattern + OOM logs | Memory leak — code or config is causing unbounded allocation | Remove cause of leak (env var, code fix) or increase limits |
| Memory stable but restarts still occur | Non-memory crash — check exit codes and stack traces | Read .NET exception logs |
| Suspicious env var altering memory behavior | Environment-driven simulation/misconfiguration | Remove or correct the env var |
| Memory usage is flat, near limit, no growth | Memory limit too low for normal workload | Increase container memory |
| Stack trace shows dependency connection failure | Database or downstream service is down | Fix dependency, not this service |
| Errors started at exact deployment time | Bad deployment introduced the issue | Rollback to previous revision |
| No recent deployment, errors appear gradually | Resource exhaustion or external change | Check connection pools, dependency health |

### .NET Memory Indicators

| Indicator | Normal | Concerning | Critical |
|-----------|--------|------------|----------|
| Working Set | < 200 MB stable | 200-800 MB growing | > 800 MB / near limit |
| GC Gen2 Collections | Infrequent | Increasing | Continuous |
| Restart Count | 0 | 1-2 in 1h | 3+ in 1h |

---

## Phase 4: FIX — Apply the Appropriate Remediation

Choose based on Phase 3 findings. Do NOT guess — apply the fix that matches the diagnosed root cause.

### Option A: Remove a Problematic Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n {{AZ_APP_PREFIX}}-meter \
  --remove-env-vars <ENV_VAR_NAME>
```

### Option B: Increase Memory Limit
```bash
az containerapp update \
  -g <resourceGroup> \
  -n {{AZ_APP_PREFIX}}-meter \
  --cpu 0.5 \
  --memory 2Gi
```

### Option C: Rollback to Previous Revision
Use the `deployment-rollback` skill for a safe rollback procedure.

### Option D: Restart the Container
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n {{AZ_APP_PREFIX}}-meter \
  -o table

az containerapp revision restart \
  -g <resourceGroup> \
  -n {{AZ_APP_PREFIX}}-meter \
  --revision <active-revision-name>
```

### Verify the Fix
```bash
# Wait 60 seconds, then:
curl -s -w "\nHTTP Status: %{http_code}\n" https://<meter-api-fqdn>/health
curl -s -w "\nHTTP Status: %{http_code}\n" https://<meter-api-fqdn>/api/meters
```

```kql
// Confirm no restarts after fix
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "{{AZ_APP_PREFIX}}-meter"
| where Log_s contains "restart" or Log_s contains "OOMKilled" or Log_s contains "killed"
| summarize Count = count()
```

```kql
// Confirm memory is stable
AzureMetrics
| where TimeGenerated > ago(30m)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "WorkingSetBytes"
| where _ResourceId contains "{{AZ_APP_PREFIX}}-meter"
| summarize AvgMemory = avg(Average), MaxMemory = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

```kql
// Confirm requests are succeeding
requests
| where timestamp > ago(15m)
| where cloud_RoleName contains "meter"
| summarize
    Total = count(),
    Success = countif(resultCode startswith "2"),
    Failed = countif(resultCode startswith "5")
by bin(timestamp, 5m)
| extend SuccessRate = round(100.0 * Success / Total, 2)
| order by timestamp desc
```

If errors persist after fix, re-enter Phase 2 with fresh data.

---

## Escalation

Escalate if:
- Root cause cannot be determined from available logs and metrics
- Memory continues to grow after removing all suspicious env vars (real application memory leak)
- The issue is in an external dependency (database, networking) outside your control
- Multiple services are experiencing restarts simultaneously
