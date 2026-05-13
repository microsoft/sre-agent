# Deployment Rollback — General Runbook

## Trigger Keywords
`rollback`, `revert`, `bad deployment`, `previous revision`, `deploy failure`, `revision`, `traffic split`

## Scope
General procedure for rolling back Azure Container Apps deployments in the PowerGrid environment. Use this when a bad deployment is identified as the root cause of an incident and the fastest remediation is to revert to the previous working revision.

---

## When to Rollback

Rollback is appropriate when:
- An incident started immediately after a deployment
- The previous revision was known to be healthy
- The fix requires a code change that will take time to develop
- The bad deployment introduced a misconfiguration (e.g., bad env vars)

Rollback is **not** appropriate when:
- The issue is infrastructure-related (database, networking)
- The previous revision has the same issue
- A database migration was applied that is incompatible with the old code

---

## Phase 1: Identify — Correlate Incident with Deployment

### 1.1 Determine When the Incident Started
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "<container-app-name>"
| where Log_s contains "error" or Log_s contains "Error" or Log_s contains "500" or Log_s contains "503"
| summarize ErrorCount = count() by bin(TimeGenerated, 5m)
| order by TimeGenerated asc
| where ErrorCount > 0
```

### 1.2 Find Deployment Events Around Incident Time
```kql
ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "<container-app-name>"
| where Log_s contains "revision"
    or Log_s contains "deploy"
    or Log_s contains "Pulling"
    or Log_s contains "Started"
    or Log_s contains "created"
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

### 1.3 Overlay Errors with Deployments
```kql
let errors = ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "<container-app-name>"
| where Log_s contains "error" or Log_s contains "500" or Log_s contains "503"
| summarize ErrorCount = count() by bin(TimeGenerated, 10m);
let deploys = ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "<container-app-name>"
| where Log_s contains "revision" or Log_s contains "Pulling"
| summarize DeployEvents = count() by bin(TimeGenerated, 10m);
errors
| join kind=fullouter deploys on TimeGenerated
| project TimeGenerated,
    ErrorCount = coalesce(ErrorCount, 0),
    DeployEvents = coalesce(DeployEvents, 0)
| order by TimeGenerated asc
```

---

## Phase 2: Prepare — List and Assess Revisions

### 2.1 List All Revisions
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n <container-app-name> \
  -o table
```

Output shows: Name, Active, Created, Traffic Weight, Health State, Provisioning State.

### 2.2 Identify the Bad and Good Revisions
```bash
# Show details of a specific revision
az containerapp revision show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <revision-name> \
  -o json
```

### 2.3 Compare Revision Configurations
```bash
# Get env vars for current (bad) revision
az containerapp show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --query "properties.template.containers[0].env" \
  -o json

# Compare with previous revision's container image/tag
az containerapp revision show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <previous-revision-name> \
  --query "properties.template.containers[0].image"
```

---

## Phase 3: Safety Checks Before Rollback

Before proceeding with rollback, verify:

| Check | Command | Pass Criteria |
|-------|---------|---------------|
| Previous revision exists | `az containerapp revision list` | Listed in output |
| Previous revision image exists in ACR | `az acr repository show-tags` | Tag exists |
| No database schema changes | Check migration history | No breaking migrations |
| No API contract changes | Review changelog | Backwards compatible |
| Previous revision was healthy | Check historical logs | No errors before this deployment |

### 3.1 Verify Previous Revision Health (Historical)
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(48h)
| where ContainerAppName_s == "<container-app-name>"
| where RevisionName_s == "<previous-revision-name>"
| where Log_s contains "error" or Log_s contains "500"
| summarize ErrorCount = count()
```

Expected: Low or zero errors for the previous revision.

---

## Phase 4: Execute Rollback

### 4.1 Activate the Previous Good Revision
```bash
az containerapp revision activate \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <previous-good-revision>
```

### 4.2 Shift Traffic to the Good Revision
```bash
# Route 100% traffic to the good revision
az containerapp ingress traffic set \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision-weight <previous-good-revision>=100
```

### 4.3 Deactivate the Bad Revision
```bash
az containerapp revision deactivate \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <bad-revision>
```

### Alternative: Gradual Traffic Shift (Canary Rollback)
```bash
# If you want to be cautious, shift traffic gradually:

# Step 1: 80/20 split
az containerapp ingress traffic set \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision-weight <previous-good-revision>=80 <bad-revision>=20

# Step 2: Monitor for 5 minutes, then go 100/0
az containerapp ingress traffic set \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision-weight <previous-good-revision>=100

# Step 3: Deactivate bad
az containerapp revision deactivate \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <bad-revision>
```

---

## Phase 5: Verify Rollback Success

### 5.1 Confirm Active Revision
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n <container-app-name> \
  --query "[?properties.active==\`true\`].{Name:name, TrafficWeight:properties.trafficWeight, Created:properties.createdTime}" \
  -o table
```

### 5.2 Confirm Error Rate Dropping
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(30m)
| where ContainerAppName_s == "<container-app-name>"
| summarize
    TotalLogs = count(),
    ErrorLogs = countif(Log_s contains "error" or Log_s contains "500" or Log_s contains "503")
by bin(TimeGenerated, 5m)
| extend ErrorRate = round(100.0 * ErrorLogs / TotalLogs, 2)
| order by TimeGenerated desc
```

### 5.3 Confirm Service Health
```bash
# Test health endpoint
curl -s -w "\nHTTP Status: %{http_code}\n" https://<app-fqdn>/health
```

### 5.4 Confirm No Restarts
```kql
AzureMetrics
| where TimeGenerated > ago(30m)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "RestartCount"
| where _ResourceId contains "<container-app-name>"
| summarize MaxRestarts = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

---

## Quick Reference — Rollback Commands

```bash
# Full rollback in 3 commands:
az containerapp revision activate -g <rg> -n <app> --revision <good-rev>
az containerapp ingress traffic set -g <rg> -n <app> --revision-weight <good-rev>=100
az containerapp revision deactivate -g <rg> -n <app> --revision <bad-rev>
```

---

## Rollback Decision Matrix

| Situation | Action | Notes |
|-----------|--------|-------|
| Bad env var introduced | Remove env var (faster than rollback) | Use `--remove-env-vars` |
| Bad code in new image | Rollback to previous revision | This runbook |
| Bad config + bad code | Rollback to previous revision | This runbook |
| Database migration issue | **Do not rollback** — fix forward | Rollback may break data |
| Infrastructure issue | **Do not rollback** — fix infrastructure | Not a deployment problem |

---

## Escalation

Escalate if:
- The previous revision is also unhealthy
- No known good revision exists
- Database schema changes prevent rollback
- Multiple services need coordinated rollback
- Rollback does not resolve the incident within 10 minutes
