---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: perf-regression-diagnosis
description: |
  Deep-dive diagnosis when deployment-validation has flagged a service
  as a perf regression (sequential or burst p95 > 1500 ms, no errors).
  Identifies whether the cause is CPU-bound code (e.g. O(n²) loop),
  slow synchronous I/O, blocking dependency, or cold-start. Produces a
  one-paragraph root-cause hypothesis suitable for the SNOW work note
  and the fix PR description.
---

# Perf Regression Diagnosis

## When to use
Invoke after `deployment-validation` returns FAIL with category
`perf` for one or more services. Input from caller: `service_name`,
`revision_name`, `deploy_time`, observed p95 from probes.

## Investigation steps

### 1. Confirm scope of slowness — which endpoints?
Use **Monitor Workspace Log Query** with:

```kusto
AppRequests
| where TimeGenerated >= datetime({DEPLOY_TIME})
| where cloud_RoleInstance has "{REVISION_NAME}"
| summarize p95 = percentile(DurationMs, 95), count() by Name
| order by p95 desc
```

If only ONE endpoint is slow → isolated code path (most likely a new
feature). If ALL endpoints are slow → infrastructure / framework / GC.

### 2. Inspect dependencies
```kusto
AppDependencies
| where TimeGenerated >= datetime({DEPLOY_TIME})
| where cloud_RoleInstance has "{REVISION_NAME}"
| summarize p95 = percentile(DurationMs, 95), count() by Type, Target
| order by p95 desc
```

If dependency p95 ≈ request p95 → downstream is the bottleneck (DB,
external API). If dependency p95 << request p95 → bottleneck is in-
process (CPU, GC, sync code).

### 3. Sample slow traces
```kusto
AppRequests
| where TimeGenerated >= datetime({DEPLOY_TIME})
| where cloud_RoleInstance has "{REVISION_NAME}"
| where DurationMs > 1500
| project TimeGenerated, Name, DurationMs, Url, OperationId
| take 5
```
For each OperationId, follow with `union AppRequests, AppDependencies,
AppExceptions, AppTraces | where OperationId == "..."` to see the full
call tree.

### 4. Compare to previous revision
Repeat (1) for the PREVIOUS revision (use the previous revision_name
from the ACA revision history) over the same kind of window. If the
prior revision had p95 < 200 ms on the same endpoint, that confirms
the new code is the cause.

### 5. Check container console logs for hot loops / GC
Use **Monitor Resource Log Query** on the Container App's console log
stream filtered by `RevisionName == "{REVISION_NAME}"`. Look for:
- Repeated identical log lines (hot loop)
- GC pause warnings
- "EVENTLOOP_BLOCKED", "long task" warnings (Node)
- Thread pool saturation (Python)
- Per-request log lines emitted from a new code path that signal a
  freshly added expensive computation in the handler.

### 6. Check chaos / latency-injection endpoints
Some services expose admin endpoints that inject server-side latency
(scenario 5 uses these to simulate organic load). For each slow
service, GET `https://<service-fqdn>/chaos/status`. If `active: true`
or `latency_ms > 0`, **that is your root cause** — not a code
regression. Disable via `DELETE /chaos/latency`. Note: this is an
ORTHOGONAL failure mode to a deploy regression — if you got here from
post-deploy validation, chaos status will normally be inactive and
the cause is in the new image.

### 7. Pinpoint the code change (REQUIRED for the SNOW summary)
A generic "latency in the code" is NOT acceptable. You must identify
the SPECIFIC change. Steps:
  a. Get the build commit SHA from the failing build:
     `GetPipelineRunHistory` on **PowerGrid-Build** for buildId
     → `sourceVersion` field.
  b. Get the previous healthy build's commit SHA the same way.
  c. Use `GetFileContents` / repo browse to inspect the diff for the
     failing service's source dir. Pay attention to:
       - new synchronous CPU-heavy loops over request payloads
         (e.g. nested loops, repeated hashing, large JSON walks)
       - new external HTTP/DB calls without timeouts
       - new locks / mutex contention
       - blocking I/O introduced into an async handler (e.g.
         `fs.readFileSync` instead of `fs.promises.readFile`)
       - new middleware registered on every request
  d. Quote the exact function name and the offending lines (≤5 lines)
     of source — verbatim from the file, with file path and line
     numbers — in the RCA.
  e. State the mechanism in plain English: WHICH function, WHAT it
     does, WHY it slows requests, by HOW MUCH (latency added per
     call, which endpoints are on the affected path, etc.).

## Output to caller
Return a structured RCA. The `code_cause` field is REQUIRED and must
quote actual source lines (verbatim from the file), not paraphrase.

Output schema (fill from your investigation — do NOT invent values):

```
PERF REGRESSION RCA
  service:        <container app name>
  revision:       <new revision name>
  deploy_time:    <UTC timestamp>
  scope:          <which endpoints are affected, from step 1>
  p95 before:     <ms on previous revision>
  p95 after:      <ms on new revision, with multiplier>
  dependencies:   <p95 of downstream calls; whether they are the bottleneck>
  chaos_endpoint: <result of /chaos/status probe, if applicable>
  console_log:    <distinctive log line(s) seen on the new revision>
  code_cause:     |
    <file path>:<line range>  <function name>
    (commit <sha>, build #<n>):

      <verbatim ≤5 lines of source from that location>

    <Plain-English mechanism: WHICH function, WHAT it does, WHY it
     slows requests, by HOW MUCH, on which endpoints.>
  fix direction: <one or more concrete options>
```

This RCA is the body for the `servicenow-incident-mgmt` work note and
the `repo-routing` PR description. The `code_cause` block goes
verbatim into the SNOW **Root Cause** section so on-callers see the
exact lines without re-investigating.
