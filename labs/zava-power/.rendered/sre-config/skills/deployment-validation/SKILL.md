---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: deployment-validation
description: |
  Authoritative runbook for validating that a just-deployed release did
  NOT introduce a regression. Combines active probing, synthetic burst
  load, and revision-scoped Application Insights queries to produce a
  per-service verdict (PASS / FAIL with category). Replaces the prior
  practice of writing ad-hoc Python in the agent. Always invoke this
  skill at the start of any post-deploy validation flow.
---

# Deployment Validation

## When to use this skill
Invoke at the start of every post-deploy validation triggered by a
`ReleaseSucceeded` event. The output of this skill is the input to
the rollback / incident decision: only `PASS` for ALL services means
the deploy is healthy.

## Why a structured skill (not ad-hoc Python)
Prior practice — agent writes urllib code on the fly — caused these
real, observed misses:

1. Active probes hit only `portal-web`; internal-ingress services were
   skipped despite the env having no VNet. Result: any regression in
   grid/meter/outage/notify was invisible.
2. Application Insights queries were not scoped to the new revision;
   aggregate metrics over 15 min mixed pre-deploy traffic and ambient
   simulator probes with the new revision and reported "P95 60ms" while
   the new revision was actually 9000ms.
3. No synthetic burst → concurrency-sensitive bugs (lock contention,
   pool exhaustion) impossible to catch.

This skill enforces every probe, scopes every query, and runs a burst.

---

## Phase 1: IDENTIFY THE NEW REVISION (per service)
For every Container App in the release, call:

```
GetActiveRevision(app_name, resource_group)
```

Record `revision_name` and `created_time_utc` for each. These are the
**only** values that should be used to scope subsequent Log Analytics
queries. Resource group is `rg-powergrid` for all PowerGrid apps.

Apps deployed by PowerGrid-Release:

| Logical service | Container App | Public URL (probe target) |
|---|---|---|
| outage-api       | ca-powergrid-outage  | https://ca-powergrid-outage.proudmoss-f0b5f310.eastus2.azurecontainerapps.io |
| meter-api        | ca-powergrid-meter   | https://ca-powergrid-meter.proudmoss-f0b5f310.eastus2.azurecontainerapps.io |
| grid-status-api  | ca-powergrid-grid    | https://ca-powergrid-grid.proudmoss-f0b5f310.eastus2.azurecontainerapps.io |
| notification-svc | ca-powergrid-notify  | https://ca-powergrid-notify.proudmoss-f0b5f310.eastus2.azurecontainerapps.io |
| portal-web       | app-powergrid-portal | https://app-powergrid-portal.azurewebsites.net |

If `GetActiveRevision` returns `health_state != Healthy` OR
`provisioning_state != Provisioned` for ANY service → immediate FAIL,
skip to "FAIL handling" below.

---

## Phase 2: ACTIVE PROBES (sequential, ground truth, no telemetry lag)
For EVERY service in the table above, call:

```
ProbeServiceLatency(service_name, url, path, count=5, timeout_s=10)
```

Suggested primary endpoints (the ones with realistic per-request CPU):

| Service          | Path           |
|------------------|----------------|
| outage-api       | /healthz       |
| meter-api        | /healthz       |
| grid-status-api  | /regions       |
| notification-svc | /healthz       |
| portal-web       | /              |

A service PASSES Phase 2 if `verdict == "PASS"` (all 5/5 OK and
p95 < 1500 ms). Otherwise it is a regression candidate — record but
continue Phase 3 to gather more data before deciding.

**Do NOT skip any service.** No-VNet means every endpoint is reachable.

---

## Phase 3: SYNTHETIC BURST (concurrency, warm telemetry)
For EVERY service that holds real traffic (skip portal-web /healthz —
portal-web is fronted by App Service, no need to burst), call:

```
BurstLoadTest(url, path, concurrency=10, duration_s=15)
```

Two purposes:
1. Detect concurrency-sensitive regressions invisible to sequential
   probes (lock contention, pool exhaustion).
2. Drive ≥ 50 requests/service into App Insights so Phase 4 KQL
   returns useful sample counts before ingestion lag is a problem.

A service PASSES Phase 3 if `verdict == "PASS"` (zero errors AND
p95 < 1500 ms).

---

## Phase 4: REVISION-SCOPED TELEMETRY (confirmation, post-warm)
Wait 60 seconds after Phase 3 to allow App Insights ingestion. Then
for each service, invoke the existing MCP tool **Monitor Workspace
Log Query** with this KQL template (substituting `{REVISION_NAME}`,
`{DEPLOY_TIME}`, `{SERVICE_NAME}`):

```kusto
AppRequests
| where TimeGenerated >= datetime({DEPLOY_TIME})
| where Properties.RevisionName == "{REVISION_NAME}"
   or cloud_RoleInstance has "{REVISION_NAME}"
| summarize
    sample_count = count(),
    p50_ms = percentile(DurationMs, 50),
    p95_ms = percentile(DurationMs, 95),
    p99_ms = percentile(DurationMs, 99),
    error_rate = todouble(countif(Success == false)) / count()
  by AppRoleName
```

Decision rules:

- `sample_count < 20`  → ingestion still cold; rely on Phases 2 + 3.
- `p95_ms > 1500`       → confirmed perf regression.
- `error_rate > 0.05`   → confirmed crash/error regression.

If Phases 2/3 said PASS but Phase 4 says FAIL, trust Phase 4 (it has
real production-like sample size).

---

## Phase 5: VERDICT MATRIX
Combine results from Phases 2 + 3 + 4 per service:

| Phase 2 | Phase 3 | Phase 4 | Verdict | Category | Next skill |
|---------|---------|---------|---------|----------|---|
| PASS | PASS | PASS or cold | PASS    | —        | (none — post Teams success) |
| FAIL (latency) | * | * | FAIL | perf  | `perf-regression-diagnosis` |
| PASS | FAIL_LATENCY | * | FAIL | perf  | `perf-regression-diagnosis` |
| * | FAIL_ERRORS | * | FAIL | crash/config (decide via Phase 4) | `crash-regression-diagnosis` if exceptions present, else `config-regression-diagnosis` |
| PASS | PASS | FAIL p95 | FAIL | perf | `perf-regression-diagnosis` |
| PASS | PASS | FAIL errors | FAIL | crash/config | as above |

---

## Output (return to caller)
Emit a structured summary like:

```
DEPLOYMENT VALIDATION RESULT
  release_id: <id>
  build_id:   <id>
  per_service:
    grid-status-api  FAIL (perf)  — probe p95=9837ms, burst err=80%
    outage-api       PASS         — probe p95=210ms, burst p95=440ms
    meter-api        PASS         — probe p95=180ms, burst p95=520ms
    notification-svc PASS         — health_state=Healthy
    portal-web       PASS         — probe p95=425ms
  overall: FAIL — proceed to perf-regression-diagnosis on grid-status-api
```

## On PASS (all services)
Post to Teams channel: "✅ Deployment <release_id> validated — no
regression found across 5 services." Include per-service p95 numbers
and link to ADO release. Done.

## On FAIL (any service)
Hand off to the per-category diagnosis skill identified in Phase 5.
Then (in order):
1. `deployment-rollback` — restore the previous healthy revision.
2. `servicenow-incident-mgmt` — open SNOW with RCA + consolidated
   chart from `plot-incident-metrics`.
3. `repo-routing` — file a fix PR against
   `placeholder-ado-org/placeholder-ado-repo` with the `sre-agent-fix` ADO build tag
   so the `release-orchestrator` agent will trigger the next release
   when the fix build succeeds.
