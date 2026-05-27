## Log Sources & Monitoring

### Log Analytics Workspace
- **Name**: `law-bookstore-ixiytoaegn4xu`
- **Workspace ID**: `ceff0903-3ad5-4a5b-9e08-ae84db500098`
- **Resource ID**: `/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-bookstore-demo/providers/Microsoft.OperationalInsights/workspaces/law-bookstore-ixiytoaegn4xu`
- **Location**: Sweden Central
- **Retention**: 30 days

### What Flows Where
| Source | Log Type | Destination |
|--------|----------|-------------|
| Container App stdout/stderr | App logs | LAW (via environment link) |
| Container App | AllMetrics | LAW (via diagnostic settings `diag-containerapp`) |
| PostgreSQL | PostgreSQLLogs, Sessions, QueryStoreRuntime, QueryStoreWaitStats, DatabaseXacts | LAW (via `diag-postgresql`) |
| PostgreSQL | AllMetrics | LAW (via `diag-postgresql`) |

### Health Probes
- **Liveness**: `GET /api/health:8000` — every 30s, restart after 3 failures
- **Startup**: `GET /api/health:8000` — every 10s, fail after 10 attempts (100s max boot)

### Alerts
| Alert | Metric | Condition | Severity | Window |
|-------|--------|-----------|----------|--------|
| `alert-no-replicas` | Replicas | avg < 1 | Sev 0 (Critical) | 5 min |
| `alert-container-restarts` | RestartCount | total > 3 | Sev 1 (Error) | 5 min |
| `alert-postgres-cpu-high` | cpu_percent | avg > 80% | Sev 1 (Error) | 5 min |

### Action Group
- **Name**: `ag-bookstore-critical` (short: `BookCrit`)
- **Receivers**: None configured yet — add email/webhook to receive notifications

### Useful KQL Queries

**Container App logs (last hour)**
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, Log_s, RevisionName_s
| order by TimeGenerated desc
```

**PostgreSQL errors (last hour)**
```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DBFORPOSTGRESQL"
| where TimeGenerated > ago(1h)
| where errorLevel_s in ("ERROR", "FATAL")
| project TimeGenerated, errorLevel_s, Message
| order by TimeGenerated desc
```

### Not Yet Configured
- Application Insights (no SDK/auto-instrumentation)
- OpenTelemetry
- Custom dashboards
