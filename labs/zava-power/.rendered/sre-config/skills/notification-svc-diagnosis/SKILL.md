---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: notification-svc-diagnosis
description: Diagnose and fix notification-svc failures including CrashLoopBackOff from missing REQUIRED_CONFIG and gateway timeout from wrong port configuration. Use when notification-svc containers crash or /send returns 502.
---

# notification-svc-diagnosis

## Scope
The **notification-svc** is a Go service (`ca-powergrid-notify`) that handles sending notifications and alerts to customers. This skill guides you through diagnosing container crashes, CrashLoopBackOff patterns, and request-level failures by systematically reading logs, checking configuration, and applying the right fix.

---

## Phase 1: DETECT — Is the Container Running?

### 1.1 Check Container Status — Running, Restarting, or Crashed?
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
    or Log_s contains "killed"
| project TimeGenerated, Log_s, RevisionName_s, Reason_s
| order by TimeGenerated desc
```

### 1.2 Check Exit Codes
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "exit code" or Log_s contains "ExitCode" or Log_s contains "exitCode"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

Exit code interpretation:
| Code | Meaning |
|------|---------|
| 0 | Normal exit (shouldn't happen for a long-running service) |
| 1 | Application error (startup validation failure, config issue) |
| 2 | Go runtime panic |
| 137 | SIGKILL (OOM killed by platform) |
| 143 | SIGTERM (graceful shutdown request) |

### 1.3 Restart Frequency
```kql
AzureMetrics
| where TimeGenerated > ago(2h)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "RestartCount"
| where _ResourceId contains "ca-powergrid-notify"
| summarize MaxRestarts = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

### 1.4 Try to Reach the Service
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" https://<notification-svc-fqdn>/health
curl -s -w "\nHTTP Status: %{http_code}\n" https://<notification-svc-fqdn>/send
```

If you get connection refused, 502, or no response — the container is not healthy. If you get a specific error response (400, 500), the container IS running but failing on requests — skip to Phase 2, section 2.5.

---

## Phase 2: INVESTIGATE — Read the Logs to Find Why

### 2.1 Read Startup Logs — What's the Last Log Before Crash?
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 100
```

Look for:
- **Missing config messages**: `not set`, `required`, `missing`, `configuration`, `FATAL`
- **Connection failures**: `connection refused`, `dial tcp`, `no such host`, `DNS`
- **Permission errors**: `permission denied`, `access denied`, `unauthorized`
- **Panic/fatal**: `panic:`, `fatal error:`, `goroutine`

The last log line before silence is often the smoking gun.

### 2.2 Go Panic / Fatal Error Stack Traces
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "panic"
    or Log_s contains "fatal"
    or Log_s contains "FATAL"
    or Log_s contains "goroutine"
    or Log_s contains "runtime error"
    or Log_s contains ".go:"
    or Log_s contains "signal"
| project TimeGenerated, Log_s
| order by TimeGenerated asc
| take 50
```

Read Go stack traces bottom-up: the goroutine dump shows which function panicked and at which line.

### 2.3 Check Environment Variables
```bash
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --query "properties.template.containers[0].env" \
  -o table
```

Look for: missing required variables, wrong values, wrong endpoint URLs, wrong port numbers.

### 2.4 Container Lifecycle Timeline
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| project TimeGenerated, Log_s, RevisionName_s, Reason_s
| order by TimeGenerated desc
| take 100
```

This shows the full cycle. A healthy container shows: Pull → Start → Running. A crashing container shows: Pull → Start → Exit → BackOff → Start → Exit → BackOff...

### 2.5 If Running But Failing — Check Request-Level Errors
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "Error"
    or Log_s contains "error"
    or Log_s contains "timeout"
    or Log_s contains "refused"
    or Log_s contains "500"
    or Log_s contains "failed"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 50
```

### 2.6 Check for DNS / Network Failures
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "dial"
    or Log_s contains "DNS"
    or Log_s contains "no such host"
    or Log_s contains "connection refused"
    or Log_s contains "ECONNREFUSED"
    or Log_s contains "i/o timeout"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

### 2.7 Check for Recent Deployments
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "revision" or Log_s contains "Pulling" or Log_s contains "Started" or Log_s contains "created"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

---

## Phase 3: ROOT CAUSE — Interpret Findings

| Finding | Likely Root Cause | Next Step |
|---------|-------------------|-----------|
| Crash on startup, exit code 1, log says "missing" or "not set" | Required environment variable is missing | Add the env var with the correct value |
| Crash on startup, exit code 1, log says "connection refused" or "dial tcp" | Service can't reach a required dependency at startup | Fix the endpoint URL or ensure the dependency is running |
| Crash on startup, exit code 2, panic with stack trace | Go runtime panic — nil pointer, index out of range, etc. | Fix the code bug or rollback |
| Crash on startup, exit code 137 | OOM kill — container uses too much memory at startup | Increase memory limit or fix startup memory usage |
| Container running but `/send` returns 502 | Ingress can't reach the container — wrong port config | Check container port matches ingress target port |
| Container running but `/send` returns 500 | Application error on the request path | Read the error logs for that endpoint |
| Container running but requests timeout | Downstream dependency is slow or unreachable | Check DNS, endpoint URLs, dependency health |
| Errors started exactly at deployment time | Bad deployment | Rollback to previous revision |

### Go Crash Pattern Reference

| Pattern | Log Signature |
|---------|---------------|
| Missing config | `FATAL: ... not set`, `missing required`, exit code 1 |
| Nil pointer dereference | `panic: runtime error: invalid memory address` |
| Go panic with stack dump | `goroutine 1 [running]:` followed by `.go:` lines |
| OOM kill | `signal: killed`, exit code 137 |
| Segfault | `signal: segmentation fault` |

---

## Phase 4: FIX — Apply the Appropriate Remediation

Choose based on Phase 3 findings. The fix depends entirely on what the logs revealed.

### Option A: Add a Missing Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --set-env-vars <ENV_VAR_NAME>=<value>
```

### Option B: Fix an Incorrect Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --set-env-vars <ENV_VAR_NAME>=<correct-value>
```

### Option C: Remove a Problematic Environment Variable
```bash
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  --remove-env-vars <ENV_VAR_NAME>
```

### Option D: Rollback to Previous Revision
Use the `deployment-rollback` skill for a safe rollback procedure.

### Verify the Fix
```bash
# Wait 30-60 seconds for new revision, then:
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-notify \
  -o table

curl -s -w "\nHTTP Status: %{http_code}\n" https://<notification-svc-fqdn>/health
```

```kql
// Confirm no more crash events
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "restart" or Log_s contains "BackOff" or Log_s contains "exit"
| summarize Count = count()
```

```kql
// Confirm healthy startup logs
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "ca-powergrid-notify"
| where Log_s contains "started" or Log_s contains "listening" or Log_s contains "ready" or Log_s contains "healthy"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

```kql
// Confirm requests are succeeding
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

If the container still crashes after your fix, re-enter Phase 2 — the original root cause diagnosis may have been incomplete. Check for a secondary failure that was masked by the first.

---

## Escalation

Escalate if:
- Root cause cannot be determined from the available logs
- The container continues to crash after applying the indicated fix
- Go panic stack traces point to a code-level bug requiring a developer
- The issue is in an external dependency or network configuration outside your control
- Multiple services are in crash loops simultaneously
