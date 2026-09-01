## Query-performance runbook (Zava)

@@SHARED@@

`Zava-products-query-slow` fires when a `/api/products/category/<X>` endpoint averages above its latency threshold (healthy baseline ~3 ms). Inspect the PostgreSQL query path, including indexes, plans, and statistics, before changing AKS capacity.

## Corroborate across logs, metrics, and traces
1. **Log** (the alert): `AppRequests | where AppRoleName == 'zava-api' | where Name startswith 'GET /api/products/category/' and Name !contains '__probe' | summarize avg(DurationMs) by Name`.
2. **Custom metric**: `AppMetrics | where Name == 'zava.products.category.query.duration_ms' | extend Category = tostring(Properties['category']) | where Category != '__probe' | summarize sum(Sum)/sum(ItemCount) by Category`.
3. **PG saturation metric**: `AzureMetrics` for `cpu_percent` on the PG server (heavy seq scans drive CPU up).
4. **Trace**: `AppDependencies` PostgreSQL-call latency.
Use agreement across these signals to locate the bottleneck.

## Cross-alert guard
Load `incident-correlation` when nearby alerts require comparison. Split
`AppDependencies` by target and result code. Slow successful PostgreSQL calls and
app-local HTTP 500 failures indicate different mechanisms. If the other alert is
already acknowledged, report the relationship and leave remediation to that thread.

## Diagnose at PostgreSQL (in-cluster SQL helper)
Use `RunKubectlWriteCommand` to execute `kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js '<SQL>'`. Inspect `pg_stat_user_indexes` (low/zero `idx_scan` on a hot table is a strong signal), `pg_stat_user_tables` (high `seq_scan`), `pg_stat_statements` (top mean-time), and `EXPLAIN`.

## Permitted autonomous actions
- Read-mostly DDL on PostgreSQL via the in-cluster helper: `CREATE INDEX CONCURRENTLY IF NOT EXISTS`, `ANALYZE`, `REINDEX CONCURRENTLY`.

## Out of scope (summarize + stop)
- `DROP`, DML, schema migrations; pod restarts / cluster scale for this alert; any IAM modification.

## Verify
The category endpoint's avg latency returns to baseline; `idx_scan` climbs on the new index; the alert auto-mitigates.
