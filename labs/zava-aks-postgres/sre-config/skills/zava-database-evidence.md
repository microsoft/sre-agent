# Zava database evidence (read-only)

Collect PostgreSQL platform metrics and application database-dependency evidence.
Use the native bounded database tool for direct PostgreSQL evidence. Do not run
`RepairZavaPostgresIndexes`, DDL, `ANALYZE`, restarts, parameter/IAM changes,
incident closure, or further delegation. SQL through Kubernetes `exec` is outside
this evidence profile even when the SQL statement only reads.

## Scope and tools

Require the question and the resources needed for that question. For Monitor
queries, require the PostgreSQL resource ID, application telemetry resource ID
and schema, and absolute UTC start/end. Read supplied reference files with
`ReadFile`; report missing scope rather than guessing it.

Use `QueryZavaPostgres` for fixed direct diagnostics,
`system-mcp-monitor_monitor_metrics_query` for platform metrics, and
`system-mcp-monitor_monitor_resource_log_query` for application evidence. Inspect
the registered tool schemas and supplied resource metadata first. Do not submit
SQL, identifiers, connection details, or other free-form input to
`QueryZavaPostgres`.
Pass the subscription ID explicitly in the Monitor tool's `subscription` argument,
including when supplying a full resource ID. Derive it from the supplied resource
ID; do not rely on an operator's default subscription.

Log Analytics uses `AppRequests`, `AppMetrics`, `AppDependencies`, `TimeGenerated`,
and `AppRoleName`. Classic App Insights uses `requests`, `customMetrics`,
`dependencies`, `timestamp`, and `cloud_RoleName`. Choose the schema for the query
target before submitting. Scope every application table to `zava-api` and use
the same absolute window.

## Collect direct PostgreSQL evidence

Choose only the operation needed for the question:

- `connection_check` confirms the configured private PostgreSQL path and identity.
- `active_sessions` shows bounded current session and wait evidence.
- `slow_queries` returns bounded `pg_stat_statements` evidence.
- `table_statistics` returns table row, dead-tuple, and analyze timestamps.
- `index_statistics` returns index scan and tuple counters.
- `category_query_plan` returns `EXPLAIN (FORMAT JSON)` for the exact category
  endpoint query shape with fixed Scenario 3 inputs (`Accessories`, limit 100,
  offset 7000). It does not use `ANALYZE`, so PostgreSQL plans but does not
  execute the workload.

Treat each result as a current or cumulative database observation, not as proof
that it occurred inside the telemetry window. Correlate it with timestamped
Monitor evidence before assigning cause. A missing row, low scan count, or slow
statement does not by itself prove that an index is missing. Treat a plan as
another bounded observation; do not authorize repair from the plan alone.

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
ARM availability checks, query-plan evaluation, and all remediation belong to
the authorized parent's workflow. Return direct index, table, session, or slow
query evidence from `QueryZavaPostgres` when relevant. Return the fixed
`category_query_plan` output when the category-query access path is relevant.
The tool does not expose arbitrary `EXPLAIN`; do not infer a missing index from
one counter, statement, or plan.
