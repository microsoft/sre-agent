# Zava database evidence (read-only)

Collect PostgreSQL platform metrics and application database-dependency evidence.
Do not execute the SQL helper, DDL, `ANALYZE`, restarts, parameter/IAM changes, incident
closure, or further delegation as part of this procedure. SQL through Kubernetes
`exec` is outside this evidence profile even when the SQL statement only reads.

## Scope and tools

Require the PostgreSQL resource ID, application telemetry resource ID and schema,
question, and absolute UTC start/end. Read supplied reference files with
`ReadFile`; report missing scope rather than guessing it.

Use `system-mcp-monitor_monitor_metrics_query` for platform metrics and
`system-mcp-monitor_monitor_resource_log_query` for application evidence. Inspect
the registered tool schemas and supplied resource metadata first.
Pass the subscription ID explicitly in the Monitor tool's `subscription` argument,
including when supplying a full resource ID. Derive it from the supplied resource
ID; do not rely on an operator's default subscription.

Log Analytics uses `AppRequests`, `AppMetrics`, `AppDependencies`, `TimeGenerated`,
and `AppRoleName`. Classic App Insights uses `requests`, `customMetrics`,
`dependencies`, `timestamp`, and `cloud_RoleName`. Choose the schema for the query
target before submitting. Scope every application table to `zava-api` and use
the same absolute window.

## Corroborate logs, metrics, and dependencies

1. Confirm category-endpoint latency from requests, excluding `__probe`. Group
   by route and success, retaining counts and duration. A slow successful request
   is different from an unavailable database.
2. Corroborate with the custom metric
   `zava.products.category.query.duration_ms`. For workspace `AppMetrics`, filter
   the role and time, extract `tostring(Properties["category"])`, exclude
   `__probe`, and compute `sum(Sum) / sum(ItemCount)` by category only where the
   denominator is positive. Classic `customMetrics` uses `name`,
   `customDimensions`, `valueSum`, and `valueCount`. Missing custom metrics are a
   gap, not a reason to fabricate agreement with request latency.
3. Query PostgreSQL `cpu_percent` with namespace
   `Microsoft.DBforPostgreSQL/flexibleServers`, aggregation `Average`, the exact
   server resource scope, and a supported interval covering the requested
   window. Select a supported grain that fits the requested bucket limit.
   Inspect supported metrics before requesting other pressure signals; do not
   guess names or intervals.
   CPU pressure supports load/inefficient-query hypotheses but not a missing-index
   verdict. Missing buckets are not zero CPU.
4. Inspect database dependencies by target, result code, success, and duration.
   Confirm which target is PostgreSQL from resource/context evidence; do not
   assume every dependency is the database. Retain failed calls and compare their
   onset with latency. Slow successful calls can coexist with independent
   application-local 500s. Return this distinction to the caller for correlation.

## Dependency queries

Choose the query for the supplied telemetry resource. Replace `<UTC_START>` and
`<UTC_END>` with the brief's absolute timestamps. Adjust the bucket size and row
limit to the task budget; report omitted intervals or targets when results are capped.

Log Analytics workspace:

```kusto
AppDependencies
| where TimeGenerated >= datetime(<UTC_START>) and TimeGenerated < datetime(<UTC_END>)
| where AppRoleName == "zava-api"
| summarize Calls=count(), AvgMs=avg(DurationMs), P95Ms=percentile(DurationMs, 95)
    by bin(TimeGenerated, 5m), Target, ResultCode, Success
| order by TimeGenerated asc, Calls desc
| take 20
```

Application Insights:

```kusto
dependencies
| where timestamp >= datetime(<UTC_START>) and timestamp < datetime(<UTC_END>)
| where cloud_RoleName == "zava-api"
| summarize Calls=count(), AvgMs=avg(duration), P95Ms=percentile(duration, 95)
    by bin(timestamp, 5m), target, resultCode, success
| order by timestamp asc, Calls desc
| take 20
```

Both `DurationMs` and classic `duration` are numeric milliseconds.
For request corroboration use workspace
`Name startswith "GET /api/products/category/"`, `Name !contains "__probe"`, and
`DurationMs`; classic fields are `name` and `duration`.

## Errors and result

Count all telemetry attempts, including failures, against any caller budget.
Default to at most 20 returned rows/buckets per query, report counts, and stop at
the task budget. Only retry a specific error correction when budget remains.
Report unavailable tools, unknown schemas, unsupported metrics, authorization
failures, blocked calls, missing intervals, empty data, and incomplete queries.
Do not route around missing access through a terminal, SQL helper, or other agent.

Return **Scope** (IDs/window/question), **Observation**, **Source** (tool/query
reference, target, schema/window), **Status** (success, empty, failed, blocked, not
attempted), **Interpretation** with alternatives, **Gaps**, and **Follow-up**.
Index usage, statistics, query plans, and ARM availability checks belong to the
authorized parent's follow-up workflow. Do not infer a missing index without
query-plan evidence.
