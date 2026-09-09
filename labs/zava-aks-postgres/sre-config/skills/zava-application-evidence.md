# Zava application evidence (read-only)

Collect application request, error, and dependency evidence. Do not roll back,
restart, change configuration/IAM, execute SQL, close incidents, or delegate
further while following this evidence procedure.

## Scope and tools

Require the question, telemetry resource ID, and absolute UTC start/end from the
caller. Read any supplied reference files with `ReadFile`. If scope is incomplete,
return the missing fields instead of guessing resources or a time window.

Use the registered `system-mcp-monitor_monitor_resource_log_query` and
`system-mcp-monitor_monitor_metrics_query` tools as needed. Inspect their current
schemas and supplied resource metadata before forming arguments.
Pass the subscription ID explicitly in the Monitor tool's `subscription` argument,
including when supplying a full resource ID. Derive it from the supplied resource
ID; do not rely on an operator's default subscription.

For a Log Analytics workspace use `AppRequests`, `AppDependencies`, `AppTraces`,
and `AppExceptions`, with `TimeGenerated` and `AppRoleName`. For classic App
Insights queries use `requests`, `dependencies`, `traces`, and `exceptions`, with
`timestamp` and `cloud_RoleName`. Select the schema for the actual query target,
not the resource's display name. Do not try both schemas repeatedly on failure.
Filter every application table to role `zava-api`.

## Procedure

1. Aggregate requests by route, result code, success, and short time buckets
   within the supplied window. Include successful traffic so a route-local 500
   is not confused with a service-wide outage. Healthy `/api/health` does not
   rule out a route-specific regression. Compare `/api/products` and category
   routes; exclude synthetic `__probe` category traffic.
2. Inspect dependencies in the same window, split by target, result code, success,
   and duration. For request/dependency linkage use workspace `OperationId` or
   classic `operation_Id`, preserving unmatched requests rather than treating
   missing dependencies as successful calls.
   A `localhost` target does not identify the calling service; establish that
   from operation context rather than assuming it is a storefront proxy.
3. Inspect a bounded set of relevant exceptions/traces for connection failures
   versus application-local errors. Match request operations when possible.
   Slow successful database dependencies alone do not explain HTTP 500 failures.
4. Return what supports and weakens each explanation. Rollout history and
   PostgreSQL ARM state are separate follow-up checks for the authorized parent;
   telemetry alone does not establish a bad deployment or stopped server.

## Request queries

Choose the query for the supplied telemetry resource. Replace `<UTC_START>` and
`<UTC_END>` with the brief's absolute timestamps. Adjust the bucket size and row
limit to the task budget; report omitted routes or intervals when results are capped.

Log Analytics workspace:

```kusto
AppRequests
| where TimeGenerated >= datetime(<UTC_START>) and TimeGenerated < datetime(<UTC_END>)
| where AppRoleName == "zava-api" and Name !contains "__probe"
| summarize Requests=count(), AvgMs=avg(DurationMs)
    by bin(TimeGenerated, 5m), Name, ResultCode, Success
| order by TimeGenerated asc, Requests desc
| take 20
```

Application Insights:

```kusto
requests
| where timestamp >= datetime(<UTC_START>) and timestamp < datetime(<UTC_END>)
| where cloud_RoleName == "zava-api" and name !contains "__probe"
| summarize Requests=count(), AvgMs=avg(duration)
    by bin(timestamp, 5m), name, resultCode, success
| order by timestamp asc, Requests desc
| take 20
```

Both `DurationMs` and classic `duration` are numeric milliseconds. Dependencies use
workspace `Target`, `ResultCode`, `Success`, `DurationMs` (classic `target`, `resultCode`,
`success`, `duration`). Retain the role and absolute-time filters in every query.

## Errors and result

Count every telemetry attempt, including failures, against any caller budget.
Use a small result limit (20 rows by default) and report returned rows/buckets
and attempt counts. Stop at the budget. Correct an argument only when the error
identifies a specific correction and budget remains. On absent tools, blocked
calls, authorization errors, or an unknown schema, report the limitation; do not
use a terminal or another agent to route around it. Empty data is not proof of
health. Report missing intervals, sampling, incomplete queries, and truncation.

Return **Scope** (IDs/window/question), **Observation** (actual results),
**Source** (tool/query reference, target, schema/window), **Status** (success,
empty, failed, blocked, not attempted), **Interpretation** (supported explanation
and alternatives), **Gaps**, and **Follow-up** (smallest discriminating check).
