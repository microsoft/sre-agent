---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: crash-regression-diagnosis
description: |
  Deep-dive diagnosis when deployment-validation has flagged a service
  with elevated 5xx errors AND exceptions present in App Insights.
  Identifies whether the cause is an unhandled exception, OOMKilled,
  ImagePullBackOff, missing dependency, or import error. Produces a
  structured RCA suitable for SNOW work note + fix PR.
---

# Crash Regression Diagnosis

## When to use
Invoke after `deployment-validation` returns FAIL with category
`crash` (5xx errors AND exceptions present in revision-scoped AI).

## Investigation steps

### 1. Top exceptions on the new revision
```kusto
AppExceptions
| where TimeGenerated >= datetime({DEPLOY_TIME})
| where cloud_RoleInstance has "{REVISION_NAME}"
| summarize count() by Type, OuterMessage
| order by count_ desc
```

### 2. Sample full stack trace
```kusto
AppExceptions
| where TimeGenerated >= datetime({DEPLOY_TIME})
| where cloud_RoleInstance has "{REVISION_NAME}"
| project TimeGenerated, Type, OuterMessage, Method, Details
| take 3
```

### 3. Check for container-level failures (OOM, ImagePullBackOff)
Use **Monitor Resource Log Query** on
`ContainerAppSystemLogs_CL` table filtered by
`RevisionName_s == "{REVISION_NAME}"`. Look for:
- `OOMKilled` — bump memory request OR fix leak
- `ImagePullBackOff` / `ErrImagePull` — image tag missing in ACR
- `CrashLoopBackOff` — process exits at startup; check console logs
- `Liveness probe failed` — endpoint never came up

### 4. Check container console logs for startup errors
```kusto
ContainerAppConsoleLogs_CL
| where TimeGenerated >= datetime({DEPLOY_TIME})
| where RevisionName_s == "{REVISION_NAME}"
| where Log_s contains "Error" or Log_s contains "Exception"
   or Log_s contains "ImportError" or Log_s contains "ModuleNotFound"
   or Log_s contains "Traceback"
| project TimeGenerated, Log_s
| take 20
```

### 5. Diff against previous revision env
If exceptions reference missing config / undefined vars, also call the
service-specific diagnosis skill (e.g. `outage-api-diagnosis`) to
inspect env-var differences vs the prior revision.

### 6. Pinpoint the code change (REQUIRED for the SNOW summary)
A generic "exception in the code" is NOT acceptable. Identify the
SPECIFIC change:
  a. Get the build commit SHA from the failing build via
     `GetPipelineRunHistory` on **PowerGrid-Build** → `sourceVersion`.
  b. Get the previous healthy build's SHA the same way.
  c. Browse the diff for the failing service — focus on the file and
     line referenced in the exception stack trace.
  d. Quote the exact function and the offending lines (≤5 lines)
     verbatim from the file, with file path and line numbers.
  e. State the mechanism: WHICH line throws, WHAT input causes it,
     WHY it slipped past tests, what the safe call should be.

## Output to caller

Output schema (fill from your investigation — do NOT invent values):

```
CRASH REGRESSION RCA
  service:        <container app name>
  revision:       <new revision name>
  deploy_time:    <UTC timestamp>
  symptom:        <which endpoint(s), what status code, what input shape>
  exception:      <Type: Message (file:line, in function)>
  count_5min:     <count> (compare to request count for the endpoint)
  prior revision: <exception count on previous revision; usually 0>
  code_cause:     |
    <file path>:<line>  <function name>
    (commit <sha>, build #<n>):

      <verbatim ≤5 lines of source from that location>

    <Plain-English mechanism: WHICH line throws, WHAT input triggers
     it, WHY it slipped past tests, the safe form of the call.>
  fix direction: <one or more concrete options>
```

Pass to `deployment-rollback` (immediate mitigation), then
`servicenow-incident-mgmt` (open ticket with this RCA), then
`repo-routing` (file fix PR with this body). The `code_cause`
block goes verbatim into the SNOW **Root Cause** section.
