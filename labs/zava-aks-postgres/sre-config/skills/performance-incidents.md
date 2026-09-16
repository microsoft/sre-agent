## Query-performance runbook (Zava)

@@SHARED@@

`Zava-products-query-slow` fires when a `/api/products/category/<X>` endpoint averages above its latency threshold (healthy baseline ~3 ms). Inspect the PostgreSQL query path, including indexes, plans, and statistics, before changing AKS capacity.

## Corroborate across logs, metrics, and traces
Read `zava-database-evidence` for category-request latency, custom query-duration
metrics, PostgreSQL CPU, and dependency evidence. Supply the server and telemetry
resource IDs, schema, and absolute UTC window. Use its sources, alternatives, and
gaps to locate the bottleneck before the direct database checks below.

## Cross-alert guard
Load `incident-correlation` when nearby alerts require comparison, using the
dependency distinctions returned by the evidence procedure. For overlapping
application failures and database latency, also read
`zava-investigation-coordination` and collect separate application and database
evidence before assigning a shared cause. Slow successful PostgreSQL calls do not
establish that PostgreSQL caused HTTP 500s; require a request/dependency or
exception trace that demonstrates that mechanism. If the other alert is
already acknowledged, report the relationship and leave remediation to that thread.

## Diagnose at PostgreSQL (native bounded tools)
Use `QueryZavaPostgres` for `slow_queries`, `table_statistics`,
`index_statistics`, and `category_query_plan`. The plan operation runs
`EXPLAIN (FORMAT JSON)` without `ANALYZE` for a fixed representative Scenario 3
request, so it preserves the application's select, category predicate,
`ORDER BY`, `LIMIT`, and `OFFSET` shape without executing the workload. The tool
caps rows, sets statement and lock timeouts, and uses a read-only transaction.
Do not submit SQL or identifiers to the tool.

Use the actual slow statement from query telemetry or `slow_queries`, including
its `ORDER BY`, `LIMIT`, and `OFFSET`, when evaluating the access pattern. A
simplified predicate-only query can hide sorting and pagination costs. Choose
the fixed category-index repair only when the full query shape, latency, query
plan, and index statistics support it. The fixed plan is evidence for the known
Scenario 3 query only; do not authorize repair from that plan alone. The tool
does not accept arbitrary `EXPLAIN`.

## Permitted autonomous actions
- Use `RepairZavaPostgresIndexes` only for its fixed category-index restore, `ANALYZE`, and concurrent reindex operations.
- Verify the returned follow-up query for every maintenance operation.
- If restore reports an exact expected index that is invalid or not ready, run
  `reindex_category_indexes` instead of retrying restore.
- If the existing index has an unexpected method, predicate, schema, table, or
  ordered columns, stop and report it. Do not reindex or drop that index.

## Out of scope (summarize + stop)
- `DROP`, DML, schema migrations; pod restarts / cluster scale for this alert; any IAM modification.

## Verify
The category endpoint's avg latency returns to baseline; `idx_scan` climbs on the new index; the alert auto-mitigates.

Compare the same query shape under comparable load before and after the change.
An index scan alone is not recovery, and a load generator ending is not proof
that the fix improved latency. If latency remains high, recheck the full query
shape and database evidence rather than assuming telemetry lag or clearing the
alert.
Verify any co-firing application failure separately after the database change.
Do not treat a low count in the latest, incomplete telemetry bucket as recovery.
