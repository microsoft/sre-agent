# Notification Service — Troubleshooting Runbook

## Trigger Keywords
`crash`, `CrashLoopBackOff`, `restart loop`, `notification-svc`, `ca-powergrid-notify`, `REQUIRED_CONFIG`, `exit code`, `container won't start`, `missing config`

## Scope
The **notification-svc** is a Go service (`ca-powergrid-notify`) that handles sending notifications and alerts to customers. This runbook covers the most common failure mode: a missing `REQUIRED_CONFIG` environment variable causing the service to crash immediately on startup, resulting in a CrashLoopBackOff pattern.

---

## Common Issue: Missing REQUIRED_CONFIG → Immediate Crash

### Symptoms
- Container restarts continuously (CrashLoopBackOff)
- Service never becomes healthy — all requests fail
- Health check endpoint is unreachable
- Container exits within seconds of starting (exit code 1)
- Logs show a startup configuration error message before crash
- No successful requests are processed
- Other services (outage-api, meter-api, grid-status-api) are unaffected

### Root Cause
The Go application requires the `REQUIRED_CONFIG` environment variable to be set at startup. During initialization, the application validates that this env var is present and has a valid value. If missing, the application logs an error and calls `os.Exit(1)` immediately. The container platform then restarts the container, which fails again — creating a CrashLoopBackOff cycle.

---

## Phase 1: Detect — Confirm Crash Loop

### 1.1 Check for Container Restart Events
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "restart"
    or Log_s contains "BackOff"
    or Log_s contains "CrashLoopBackOff"
    or Log_s contains "Unhealthy"
    or Log_s contains "exit"
    or Log_s contains "terminated"
    or Log_s contains "Failed"
| project TimeGenerated, Log_s, RevisionName_s, Reason_s
| order by TimeGenerated desc
```

### 1.2 Check Console Logs for Crash Message
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 100
```

Look for messages like:
- `FATAL: REQUIRED_CONFIG environment variable is not set`
- `configuration validation failed`
- `missing required configuration`
- `panic:` or `fatal error:`

### 1.3 Check Exit Codes
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "exit code" or Log_s contains "ExitCode" or Log_s contains "exitCode"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

Expected: Exit code 1 (application error) appearing repeatedly.

### 1.4 Restart Frequency
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "restart" or Log_s contains "Started" or Log_s contains "Pulling"
| summarize RestartCount = count() by bin(TimeGenerated, 10m)
| order by TimeGenerated desc
```

### 1.5 Restart Count Metric
```kql
AzureMetrics
| where TimeGenerated > ago(2h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "RestartCount"
| where _ResourceId contains "ca-powergrid-notify"
| summarize MaxRestarts = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

---

## Phase 2: Diagnose — Go Crash Pattern Analysis

### 2.1 Check Environment Variables
```bash
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --query "properties.template.containers[0].env" \
  -o table
```

**If `REQUIRED_CONFIG` is not in the list** → this is the root cause.

### 2.2 Go Panic / Fatal Error Analysis
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "panic"
    or Log_s contains "fatal"
    or Log_s contains "FATAL"
    or Log_s contains "goroutine"
    or Log_s contains "runtime error"
    or Log_s contains "signal"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

### 2.3 Go Stack Trace Extraction
```kql
// Go panics produce multi-line stack traces
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "goroutine" or Log_s contains ".go:" or Log_s contains "panic"
| project TimeGenerated, Log_s
| order by TimeGenerated asc
| take 50
```

### 2.4 Container Lifecycle Timeline
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| project TimeGenerated, Log_s, RevisionName_s, Reason_s
| order by TimeGenerated desc
| take 100
```

This shows the full cycle: Pull → Start → Crash → BackOff → Restart → Pull → Start → Crash…

### 2.5 Time Between Crashes (BackOff Pattern)
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "Started" or Log_s contains "started"
| project StartTime = TimeGenerated
| order by StartTime asc
| extend PrevStart = prev(StartTime)
| extend TimeBetweenRestarts = datetime_diff('second', StartTime, PrevStart)
| where isnotnull(PrevStart)
```

BackOff pattern: intervals grow (10s → 20s → 40s → 80s → capped at 300s).

---

## Phase 3: Fix — Add REQUIRED_CONFIG

### 3.1 Add the Missing Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --set-env-vars REQUIRED_CONFIG=enabled
```

### 3.2 Verify the Fix
```bash
# Wait 30-60 seconds for new revision to start, then:

# Check env vars include REQUIRED_CONFIG
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --query "properties.template.containers[0].env" \
  -o table

# Check revision status
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  -o table

# Test health endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<notification-svc-fqdn>/health
```

### 3.3 Confirm Container is Stable
```bash
# Wait 2-3 minutes and check no more restarts
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --query "properties.latestRevisionName"
```

---

## Phase 4: Verify — Confirm Service is Running

### 4.1 No More Crash Events
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "restart" or Log_s contains "BackOff" or Log_s contains "exit"
| summarize Count = count()
```

Expected: Count = 0.

### 4.2 Healthy Logs Appearing
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "started" or Log_s contains "listening" or Log_s contains "ready" or Log_s contains "healthy"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

Expected: Startup success messages, listening on port 8080.

### 4.3 Service Responding to Requests
```kql
requests
| where timestamp > ago(15m)
| where cloud_RoleName contains "notify"
| summarize
    Total = count(),
    Success = countif(resultCode startswith "2"),
    Failed = countif(resultCode startswith "5")
by bin(timestamp, 5m)
| order by timestamp desc
```

---

## Go Crash Patterns Reference

| Pattern | Log Signature | Meaning |
|---------|---------------|---------|
| Missing config | `FATAL: ... not set`, exit code 1 | Required env var missing |
| Nil pointer | `panic: runtime error: invalid memory address` | Nil dereference in Go code |
| Goroutine leak | `goroutine 1 [running]:` + stack trace | Go panic with stack dump |
| Signal kill | `signal: killed` | OOM kill by platform |
| Segfault | `signal: segmentation fault` | Memory access violation |

### Go Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Normal exit |
| 1 | Application error (most common — config validation failure) |
| 2 | Go runtime panic |
| 137 | SIGKILL (OOM killed) |
| 143 | SIGTERM (graceful shutdown) |

---

## Other Possible Issues

| Symptom | Possible Cause | Investigation |
|---------|----------------|---------------|
| Crash loop, exit code 1 | Missing `REQUIRED_CONFIG` | Check env vars (this runbook) |
| Crash loop, exit code 137 | OOM kill | Check memory metrics |
| Crash loop, exit code 2 | Go runtime panic | Check for panic stack traces |
| Running but 500 errors | Application logic bug | Check console logs for errors |
| Running but slow | Resource contention | Check CPU/memory metrics |

---

## Escalation

Escalate if:
- Adding `REQUIRED_CONFIG=enabled` does not stop the crash loop
- Container crashes with a different exit code after adding the env var
- Go panic stack traces indicate a code-level bug
- Multiple services are in crash loops simultaneously
