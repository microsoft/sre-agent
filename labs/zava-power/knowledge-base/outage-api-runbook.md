# Outage API — Troubleshooting Runbook

## Trigger Keywords
`503 error`, `service unavailable`, `outage-api`, `FORCE_ERROR`, `ca-powergrid-outage`, `outage endpoint failing`

## Scope
The **outage-api** is a Python/Flask service (`ca-powergrid-outage`) that manages power outage reports. This runbook covers the most common failure mode: the `FORCE_ERROR` environment variable causing HTTP 503 on all endpoints.

---

## Common Issue: FORCE_ERROR Causing 503 on All Endpoints

### Symptoms
- All requests to outage-api return **HTTP 503 Service Unavailable**
- Health check endpoint `/health` also returns 503
- Other services (meter-api, grid-status-api) are healthy
- No OOM or restart events — the container is running but rejecting requests
- Logs show explicit "FORCE_ERROR" or "forced error" messages

### Root Cause
The `FORCE_ERROR` environment variable is set to `true` on the container app. When this env var is present and set to `true`, the Flask application middleware intercepts all incoming requests and immediately returns HTTP 503 without processing them. This simulates a service-level failure.

---

## Phase 1: Detect — Confirm the Issue

### 1.1 Check for 503 Errors in Logs
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "503" or Log_s contains "Service Unavailable"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
| take 50
```

### 1.2 Check for FORCE_ERROR in Logs
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "FORCE_ERROR" or Log_s contains "forced error" or Log_s contains "force_error"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

### 1.3 Error Rate Over Time
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(2h)
| where ContainerAppName_s == "ca-powergrid-outage"
| summarize
    TotalLogs = count(),
    ErrorLogs = countif(Log_s contains "503" or Log_s contains "error" or Log_s contains "Error")
by bin(TimeGenerated, 5m)
| extend ErrorRate = round(100.0 * ErrorLogs / TotalLogs, 2)
| order by TimeGenerated desc
```

### 1.4 Confirm via HTTP Request
```bash
# Direct health check — should return 200 if healthy
curl -s -o /dev/null -w "%{http_code}" https://<outage-api-fqdn>/health

# Check outages endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<outage-api-fqdn>/api/outages
```

**Expected when FORCE_ERROR is active:**
```
HTTP Status: 503
{"error": "Service Unavailable", "message": "Forced error mode is enabled"}
```

**Expected when healthy:**
```
HTTP Status: 200
{"status": "healthy"}
```

---

## Phase 2: Diagnose — Verify Environment Variable

### 2.1 Check Environment Variables via CLI
```bash
# Show current env vars for outage-api
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --query "properties.template.containers[0].env" \
  -o table
```

Look for:
```json
{
  "name": "FORCE_ERROR",
  "value": "true"
}
```

### 2.2 Check Container App Configuration
```bash
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  -o json
```

### 2.3 Check When the Error Started
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "503" or Log_s contains "FORCE_ERROR"
| summarize FirstError = min(TimeGenerated), LastError = max(TimeGenerated), ErrorCount = count()
```

### 2.4 Correlate with Deployment
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "revision" or Log_s contains "deploy" or Log_s contains "Pulling"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

---

## Phase 3: Fix — Remove FORCE_ERROR

### 3.1 Remove the Environment Variable
```bash
# Remove FORCE_ERROR env var (sets env vars WITHOUT FORCE_ERROR)
az containerapp update \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --remove-env-vars FORCE_ERROR
```

### 3.2 Verify the Fix
```bash
# Wait 30-60 seconds for new revision to activate, then:

# Check env vars are clean
az containerapp show \
  -g <resourceGroup> \
  -n ca-powergrid-outage \
  --query "properties.template.containers[0].env" \
  -o table

# Test health endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<outage-api-fqdn>/health

# Test outages endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<outage-api-fqdn>/api/outages
```

### 3.3 Confirm Recovery in Logs
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "ca-powergrid-outage"
| where Log_s contains "200" or Log_s contains "healthy" or Log_s contains "started"
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

---

## Phase 4: Verify — Confirm No Residual Issues

### 4.1 Error Rate After Fix
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(30m)
| where ContainerAppName_s == "ca-powergrid-outage"
| summarize
    TotalLogs = count(),
    ErrorLogs = countif(Log_s contains "503" or Log_s contains "error")
by bin(TimeGenerated, 5m)
| extend ErrorRate = round(100.0 * ErrorLogs / TotalLogs, 2)
| order by TimeGenerated desc
```

### 4.2 Request Success Rate (App Insights)
```kql
requests
| where timestamp > ago(30m)
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

## Request/Response Pattern Examples

### Healthy Response — GET /api/outages
```http
GET /api/outages HTTP/1.1
Host: ca-powergrid-outage.internal

HTTP/1.1 200 OK
Content-Type: application/json

[
  {
    "id": "OUT-001",
    "region": "northeast",
    "status": "active",
    "reported_at": "2025-01-15T14:30:00Z",
    "affected_customers": 1250,
    "estimated_restoration": "2025-01-15T18:00:00Z"
  }
]
```

### Error Response — FORCE_ERROR Active
```http
GET /api/outages HTTP/1.1
Host: ca-powergrid-outage.internal

HTTP/1.1 503 Service Unavailable
Content-Type: application/json

{
  "error": "Service Unavailable",
  "message": "Forced error mode is enabled"
}
```

---

## Other Possible Issues

| Symptom | Possible Cause | Investigation |
|---------|----------------|---------------|
| 503 on all endpoints | `FORCE_ERROR=true` | Check env vars (this runbook) |
| 500 on POST /api/outages | Database connection failure | Check Azure SQL connectivity |
| 404 on /api/outages/{id} | Invalid outage ID | Check request payload |
| Slow responses (>2s) | Database query performance | Check SQL metrics |
| Connection refused | Container not running | Check revision status and restarts |

---

## Escalation

Escalate if:
- Removing `FORCE_ERROR` does not resolve the 503 errors
- 503 errors persist after new revision is active (>5 minutes)
- Database connectivity issues are the root cause
- Multiple services are simultaneously affected
