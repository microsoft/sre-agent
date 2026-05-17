---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: deployment-rollback
description: Execute safe rollback of Azure Container Apps to a previous healthy revision. Use after identifying a bad deployment as root cause. Includes pre-rollback safety checks and validation steps.
---

# deployment-rollback

## Scope
Generic procedure for safely rolling back any Azure Container App to a previous healthy revision. This skill covers the full lifecycle: identifying which revision to roll back to, pre-rollback safety checks, executing the rollback, and validating recovery.

---

## When to Use This Skill

Rollback is appropriate when:
- An incident started immediately after a deployment
- The previous revision was known to be healthy
- The fix requires a code change that will take time to develop
- The bad deployment introduced a misconfiguration

Rollback is **NOT** appropriate when:
- The issue is infrastructure-related (database, networking) — fix the infrastructure instead
- The previous revision has the same issue — rollback won't help
- A database migration was applied that is incompatible with old code — fix forward instead

---

## Phase 1: IDENTIFY — List Revisions and Determine Which Is Healthy

### 1.1 List All Revisions
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n <container-app-name> \
  -o table
```

Note the output columns: **Name**, **Active**, **Created**, **Traffic Weight**, **Health State**, **Provisioning State**.

Identify:
- **Current (potentially bad) revision**: the one receiving traffic now
- **Previous revision(s)**: candidates for rollback

### 1.2 Inspect a Specific Revision
```bash
az containerapp revision show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <revision-name> \
  -o json
```

### 1.3 Compare Configurations Between Revisions
```bash
# Current revision's env vars
az containerapp show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --query "properties.template.containers[0].env" \
  -o json

# Current revision's image
az containerapp show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --query "properties.template.containers[0].image" \
  -o tsv

# Previous revision's image (to see what changed)
az containerapp revision show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <previous-revision-name> \
  --query "properties.template.containers[0].image" \
  -o tsv
```

### 1.4 Confirm Deployment Correlates with Incident Onset
```kql
let errors = ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "<container-app-name>"
| where Log_s contains "error" or Log_s contains "Error" or Log_s contains "500" or Log_s contains "503"
| summarize ErrorCount = count() by bin(TimeGenerated, 10m);
let deploys = ContainerAppSystemLogs_CL
| where TimeGenerated > ago(24h)
| where ContainerAppName_s == "<container-app-name>"
| where Log_s contains "revision" or Log_s contains "Pulling" or Log_s contains "created"
| summarize DeployEvents = count() by bin(TimeGenerated, 10m);
errors
| join kind=fullouter deploys on TimeGenerated
| project TimeGenerated,
    ErrorCount = coalesce(ErrorCount, 0),
    DeployEvents = coalesce(DeployEvents, 0)
| order by TimeGenerated asc
```

If errors spiked at the same time as a deploy event, the deployment is confirmed as the cause.

---

## Phase 2: PRE-ROLLBACK SAFETY CHECKS

Before rolling back, verify each of these:

### 2.1 Is the Previous Revision Still Available?
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n <container-app-name> \
  -o table
```

The target revision must appear in the list. If it's been garbage-collected, you cannot roll back to it.

### 2.2 Was the Previous Revision Actually Healthy?
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(48h)
| where ContainerAppName_s == "<container-app-name>"
| where RevisionName_s == "<previous-revision-name>"
| where Log_s contains "error" or Log_s contains "Error" or Log_s contains "500"
| summarize ErrorCount = count()
```

If ErrorCount is high for the previous revision too, rolling back won't help. Find an older healthy revision or fix forward.

### 2.3 Were There Database Migrations?
Check whether the current deployment included schema changes. If it did, rolling back to old code that expects the old schema may break things. If unsure, check with the development team before proceeding.

### 2.4 Will Rollback Break Other Services?
If the new revision introduced a new API contract that other services now depend on, rolling back will break those callers. Check whether other services were deployed at the same time.

### Safety Check Summary

| Check | How to Verify | Pass Criteria |
|-------|---------------|---------------|
| Previous revision exists | `az containerapp revision list` | Listed in output |
| Previous revision was healthy | Query historical logs above | Low/zero error count |
| No breaking database migrations | Check deployment notes/changelog | No schema changes |
| No breaking API contract changes | Check caller dependencies | Backwards compatible |

---

## Phase 3: EXECUTE ROLLBACK

### 3.0 CRITICAL — Detect Revision Mode FIRST
The rollback procedure differs based on the container app's revision mode.
**Always check this first** — calling `ingress traffic set` against a Single
mode app will fail with: *"Containerapp '<name>' is configured for single
revision. Set revision mode to multiple in order to set ingress traffic."*

```bash
az containerapp show \
  -g <resourceGroup> \
  -n <container-app-name> \
  --query "properties.configuration.activeRevisionsMode" \
  -o tsv
```

- Output `Single` → use **3.1A** (image-swap rollback)
- Output `Multiple` → use **3.1B** (traffic-shift rollback)

---

### 3.1A Single-Revision Mode Rollback (image swap)

In single-revision mode, only one revision serves traffic and it is always
the *latest* one. To roll back you create a NEW revision pointing at the
previous container image — do NOT activate the old revision and do NOT
attempt to set traffic weights.

Step 1 — discover the previous good image tag (the image of the revision
that was active immediately before the bad one):
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n <container-app-name> \
  --all \
  --query "sort_by([], &properties.createdTime)[-3:].{name:name, image:properties.template.containers[0].image, created:properties.createdTime}" \
  -o table
```

Step 2 — execute the rollback by updating the image. This creates a new
revision whose code is the previous-good code, immediately taking traffic:
```bash
az containerapp update \
  -g <resourceGroup> \
  -n <container-app-name> \
  --image <previous-good-image> \
  --revision-suffix "rollback$(date +%H%M%S)"
```

The `--revision-suffix` makes the rollback revision easy to identify in
later audits (e.g. `{{AZ_APP_PREFIX}}-grid--rollback143052`).

Step 3 — confirm the new active revision:
```bash
az containerapp revision list -g <rg> -n <app> \
  --query "[?properties.active] | [].{name:name, image:properties.template.containers[0].image}" \
  -o table
```

The bad revision is automatically deactivated by ACA when the new revision
becomes ready (single-revision mode behavior). No deactivate call needed.

> Tip — for PowerGrid services the convention is that a stable image tag
> (`acrpowergrid.azurecr.io/<service>:stable`) always points at the last
> known-good build. If unsure of the previous build's numeric tag, swap to
> `:stable` instead.

---

### 3.1B Multiple-Revision Mode Rollback (traffic shift)

Only use these commands when `activeRevisionsMode == "Multiple"`.

```bash
az containerapp revision activate \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <previous-good-revision>

az containerapp ingress traffic set \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision-weight <previous-good-revision>=100

az containerapp revision deactivate \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <bad-revision>
```

### Alternative: Gradual Traffic Shift (Canary Rollback) — Multiple mode only
If you want to be cautious, shift traffic gradually:
```bash
# Step 1: 80/20 split — send most traffic to the good revision
az containerapp ingress traffic set \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision-weight <previous-good-revision>=80 <bad-revision>=20

# Step 2: Monitor for 5 minutes, then shift fully
az containerapp ingress traffic set \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision-weight <previous-good-revision>=100

# Step 3: Deactivate the bad revision
az containerapp revision deactivate \
  -g <resourceGroup> \
  -n <container-app-name> \
  --revision <bad-revision>
```

### Quick Reference

**Single-revision mode (most common for PowerGrid services):**
```bash
# Detect mode + roll back via image swap to the :stable tag in 1 line
PREV_IMG=$(az containerapp revision list -g <rg> -n <app> --all \
  --query "sort_by([?properties.active==\`false\`], &properties.createdTime)[-1].properties.template.containers[0].image" -o tsv)
az containerapp update -g <rg> -n <app> --image "$PREV_IMG" \
  --revision-suffix "rollback$(date +%H%M%S)"
```

**Multiple-revision mode:**
```bash
# Full rollback in 3 commands:
az containerapp revision activate -g <rg> -n <app> --revision <good-rev>
az containerapp ingress traffic set -g <rg> -n <app> --revision-weight <good-rev>=100
az containerapp revision deactivate -g <rg> -n <app> --revision <bad-rev>
```

---

## Phase 4: VALIDATE — Confirm Rollback Success

### 4.1 Confirm Active Revision
```bash
az containerapp revision list \
  -g <resourceGroup> \
  -n <container-app-name> \
  --query "[?properties.active==\`true\`].{Name:name, TrafficWeight:properties.trafficWeight, Created:properties.createdTime}" \
  -o table
```

The good revision should be the only active revision with 100% traffic.

### 4.2 Health Check
```bash
curl -s -w "\nHTTP Status: %{http_code}\n" https://<app-fqdn>/health
```

### 4.3 Error Rate After Rollback
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(15m)
| where ContainerAppName_s == "<container-app-name>"
| summarize
    TotalLogs = count(),
    ErrorLogs = countif(Log_s contains "error" or Log_s contains "Error" or Log_s contains "500" or Log_s contains "503")
by bin(TimeGenerated, 5m)
| extend ErrorRate = round(100.0 * ErrorLogs / TotalLogs, 2)
| order by TimeGenerated desc
```

Error rate should be dropping toward 0%.

### 4.4 Latency Returned to Normal
```kql
requests
| where timestamp > ago(15m)
| where cloud_RoleName contains "<service-name>"
| summarize
    AvgDuration = avg(duration),
    P95 = percentile(duration, 95)
by bin(timestamp, 5m)
| order by timestamp desc
```

### 4.5 No Container Restarts
```kql
AzureMetrics
| where TimeGenerated > ago(15m)
| where ResourceProvider == "MICROSOFT.APP"
| where MetricName == "RestartCount"
| where _ResourceId contains "<container-app-name>"
| summarize MaxRestarts = max(Maximum) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

If any validation step fails, investigate whether the previous revision also has issues. You may need to find an even older revision or fix forward.

---

## Rollback Decision Matrix

| Situation | Recommended Action |
|-----------|-------------------|
| Bad env var introduced | Remove env var with `--remove-env-vars` (faster than rollback) |
| Bad code in new container image | Rollback to previous revision (this skill) |
| Bad config + bad code | Rollback to previous revision (this skill) |
| Database migration applied | **Do NOT rollback** — fix forward to avoid data integrity issues |
| Infrastructure issue (networking, DB down) | **Do NOT rollback** — fix the infrastructure |

---

## Escalation

Escalate if:
- The previous revision is also unhealthy
- No known good revision exists (all revisions have been garbage-collected)
- Database schema changes prevent safe rollback
- Multiple services need coordinated rollback
- Rollback does not resolve the incident within 10 minutes
