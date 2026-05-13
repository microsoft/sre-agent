---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: outage-api-diagnosis
description: Diagnose and fix outage-api failures including HTTP 500/503 errors, SCADA enrichment crashes, and FORCE_ERROR issues. Use when outage-api health checks fail or /outages endpoint returns errors.
---

# outage-api-diagnosis

## Scope
The **outage-api** is a Python/Flask service (`ca-powergrid-outage`) that manages power outage reports. This skill guides you through a systematic investigation of any failure in this service — from detecting symptoms, through root-cause analysis of Python tracebacks, to applying the appropriate fix.

---

## Phase 1: DETECT — Identify Symptoms

### 1.1 Check Service Health
```bash
# Test health endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<outage-api-fqdn>/health

# Test functional endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<outage-api-fqdn>/api/outages
```

Compare the results: does `/health` pass while other endpoints fail, or do ALL endpoints fail? This distinction narrows the investigation.

### 1.2 Query Console Logs for Errors and Tracebacks
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "Error"
    or Log_s contains "Traceback"
    or Log_s contains "Exception"
    or Log_s contains "500"
    or Log_s contains "503"
    or Log_s contains "FATAL"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 50
```

### 1.3 Error Rate Over Time — When Did It Start?
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(6h)
| where ContainerAppName_s == "ca-powergrid-outage"
| summarize
    TotalLogs = count(),
    ErrorLogs = countif(Log_s contains "Error" or Log_s contains "Exception" or Log_s contains "500" or Log_s contains "503")
by bin(TimeGenerated, 5m)
| extend ErrorRate = round(100.0 * ErrorLogs / TotalLogs, 2)
| order by TimeGenerated asc
```

Look for the inflection point — when did errors start? Note this timestamp for Phase 2.

### 1.4 App Insights Request Failures
```kql
requests
| where timestamp > ago(2h)
| where cloud_RoleName contains "outage"
| summarize
    Total = count(),
    Success = countif(resultCode startswith "2"),
    ServerErrors = countif(resultCode startswith "5"),
    ClientErrors = countif(resultCode startswith "4")
by bin(timestamp, 5m)
| extend ErrorRate = round(100.0 * ServerErrors / Total, 2)
| order by timestamp desc
```

### 1.5 Check Container Status — Is It Running?
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "restart"
    or Log_s contains "Unhealthy"
    or Log_s contains "BackOff"
    or Log_s contains "killed"
    or Log_s contains "exit"
| project TimeGenerated, Log_s, RevisionName_s, Reason_s
| order by TimeGenerated desc
```

---

## Phase 2: INVESTIGATE — Find the Root Cause

### 2.1 Read the Full Python Traceback
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "Traceback"
    or Log_s contains "File \""
    or Log_s contains "raise "
    or Log_s has_any ("TypeError", "ValueError", "KeyError", "AttributeError", "ImportError", "ConnectionError", "NoneType")
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 50
```

Read the traceback bottom-up. Identify: **which file**, **which line**, **which function**, and **what exception type** was raised.

### 2.2 Check Environment Variables
```bash
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --query "properties.template.containers[0].env" \
  -o table
```

Look for anything suspicious: unexpected values, missing expected vars, or vars that could change service behavior (e.g., feature flags, error simulation flags, wrong database URLs).

### 2.3 Check for Recent Deployments — Correlate with Error Onset
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "revision" or Log_s contains "Pulling" or Log_s contains "Started" or Log_s contains "created"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

Did the errors start immediately after a new revision was deployed? If so, the deployment is likely the cause.

### 2.4 Compare Current vs Previous Revision
```bash
# List all revisions
az containerapp revision list \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  -o table

# Check current revision's container image
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --query "properties.template.containers[0].image" \
  -o tsv

# Check current revision's env vars
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --query "properties.template.containers[0].env" \
  -o json
```

### 2.5 App Insights Exception Details
```kql
exceptions
| where timestamp > ago(2h)
| where cloud_RoleName contains "outage"
| summarize Count = count(), FirstSeen = min(timestamp), LastSeen = max(timestamp)
by type, problemId, outerMessage
| order by Count desc
```

### 2.6 Check Dependency Failures
```kql
dependencies
| where timestamp > ago(1h)
| where cloud_RoleName contains "outage"
| where success == false
| summarize FailureCount = count() by target, type, resultCode
| order by FailureCount desc
```

---

## Phase 3: ROOT CAUSE — Interpret Findings

Based on your investigation in Phase 2, match your findings to one of these common patterns:

| Finding | Likely Root Cause | Next Step |
|---------|-------------------|-----------|
| Traceback shows `NoneType` / `AttributeError` | Code bug — variable is None when it shouldn't be | Fix code or rollback revision |
| Traceback shows `ImportError` / `ModuleNotFoundError` | Missing dependency in container image | Rebuild image or rollback |
| Traceback shows `ConnectionError` / `ConnectionRefusedError` | Downstream dependency is unreachable | Check database/dependency health |
| Traceback shows `KeyError` on config | Missing or wrong environment variable | Add/fix the env var |
| All endpoints return same HTTP error, no traceback | Middleware or env-var-driven error mode | Check env vars for flags that alter behavior |
| Errors started exactly when a new revision deployed | Bad deployment | Rollback to previous revision |
| Errors started without any deployment | External dependency failure or config change | Check dependencies and config sources |
| `500` on specific endpoints only | Endpoint-specific code bug | Read traceback for that endpoint |

---

## Phase 4: FIX — Apply the Appropriate Remediation

Choose the fix based on what Phase 3 revealed. Do NOT apply a fix without first confirming the root cause.

### Option A: Remove or Fix a Problematic Environment Variable
```bash
# Remove a problematic env var
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --remove-env-vars <ENV_VAR_NAME>

# Or set an env var to the correct value
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --set-env-vars <ENV_VAR_NAME>=<correct-value>
```

### Option B: Rollback to Previous Revision
Use the `deployment-rollback` skill for a safe rollback procedure.

### Option C: Restart the Container
```bash
az containerapp revision restart \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --revision <active-revision-name>
```

### Verify the Fix
```bash
# Wait 30-60 seconds, then:
curl -s -w "\nHTTP Status: %{http_code}\n" https://<outage-api-fqdn>/health
curl -s -w "\nHTTP Status: %{http_code}\n" https://<outage-api-fqdn>/api/outages
```

```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "Error" or Log_s contains "Traceback" or Log_s contains "Exception"
| summarize ErrorCount = count()
```

Confirm: ErrorCount should be 0 or near 0 after the fix. If errors persist, re-enter Phase 2 with the new data.

```kql
requests
| where timestamp > ago(15m)
| where cloud_RoleName contains "outage"
| summarize
    Total = count(),
    Success = countif(resultCode startswith "2"),
    Failed = countif(resultCode startswith "5")
by bin(timestamp, 5m)
| extend SuccessRate = round(100.0 * Success / Total, 2)
| order by timestamp desc
```

---

## Escalation

Escalate if:
- The root cause cannot be determined from logs and traces
- The fix does not resolve errors within 5 minutes
- The issue is in an external dependency outside your control
- Multiple services are simultaneously affected
