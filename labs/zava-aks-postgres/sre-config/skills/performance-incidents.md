## Query-performance runbook (Zava)

@@SHARED@@

`Zava-products-query-slow` fires when a `/api/products/category/<X>` endpoint averages above its latency threshold (healthy baseline ~3 ms). Inspect the PostgreSQL query path, including indexes, plans, and statistics, before changing AKS capacity.

## Corroborate across logs, metrics, and traces
Read `zava-database-evidence` for category-request latency, custom query-duration
metrics, PostgreSQL CPU, and dependency evidence. Supply the server and telemetry
resource IDs, schema, and absolute UTC window. Use its sources, alternatives, and
gaps to locate the bottleneck before the query-plan checks below.

## Cross-alert guard
Load `incident-correlation` when nearby alerts require comparison, using the
dependency distinctions returned by the evidence procedure. For overlapping
application failures and database latency, also read
`zava-investigation-coordination` and collect separate application and database
evidence before assigning a shared cause. Slow successful PostgreSQL calls do not
establish that PostgreSQL caused HTTP 500s; require a request/dependency or
exception trace that demonstrates that mechanism. If the other alert is
already acknowledged, report the relationship and leave remediation to that thread.

## Diagnose at PostgreSQL (in-cluster SQL helper)
Use `RunKubectlWriteCommand` to execute `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'`. Inspect `pg_stat_user_indexes` (low/zero `idx_scan` on a hot table is a strong signal), `pg_stat_user_tables` (high `seq_scan`), `pg_stat_statements` (top mean-time), and `EXPLAIN`.

Use the actual slow statement from query telemetry or `pg_stat_statements`,
including its `ORDER BY`, `LIMIT`, and `OFFSET`, when evaluating the plan. A
simplified predicate-only query can hide sorting and pagination costs. Choose
an index from the full access pattern rather than stopping at any index scan.

## Permitted autonomous actions
- Read-mostly DDL on PostgreSQL via the in-cluster helper: `CREATE INDEX CONCURRENTLY IF NOT EXISTS`, `ANALYZE`, `REINDEX CONCURRENTLY`.

## Out of scope (summarize + stop)
- `DROP`, DML, schema migrations; pod restarts / cluster scale for this alert; any IAM modification.

## Verify
The category endpoint's avg latency returns to baseline; `idx_scan` climbs on the new index; the alert auto-mitigates.

Compare the same query shape under comparable load before and after the change.
An index scan alone is not recovery, and a load generator ending is not proof
that the fix improved latency. If latency remains high, recheck the full query
plan rather than assuming telemetry lag or clearing the alert.
Verify any co-firing application failure separately after the database change.
Do not treat a low count in the latest, incomplete telemetry bucket as recovery.
