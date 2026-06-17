## Bookstore Application — Hybrid Migration

Bookstore app originally running on-prem, modernized and deployed to Azure via AppMod. Both versions may run simultaneously during migration.

### Architecture
| Component | On-Prem | Azure |
|-----------|---------|-------|
| Compute | Docker container | Container Apps (`ca-bookstore-ixiytoaegn4xu`) |
| Database | SQLite (local file) | PostgreSQL Flexible Server (`pg-ixiytoaegn4xu`) |
| Images | — | Container Registry (`crixiytoaegn4xu`) |
| Logs | Structured JSON via API | stdout → Log Analytics (`law-bookstore-ixiytoaegn4xu`) |
| Monitoring | Health/metrics/logs endpoints | Log Analytics + health probes + alerts configured |

### On-Prem Endpoints
- `/api/health` — DB status, latency, active failure mode
- `/api/metrics` — request/error counts, avg latency, 5-min window
- `/api/logs?last=N` — structured JSON logs
- `/api/books` — catalog listing
- `/api/orders` — order processing

### On-Prem Log Patterns
- `"level": "error"` + `"event": "db_write_failed"` → DB corruption/lock
- `"event": "search_timeout"` → search dependency slow/down
- `"event": "health_check_failed"` → DB connectivity lost
- High `duration_ms` → resource contention

### Incident Management
- **ServiceNow** for both on-prem and cloud issues
- Diagnosis flow: read incident → check affected system → diagnose → post findings to work notes

### Observability (configured 2026-05-13)
- **Log Analytics**: `law-bookstore-ixiytoaegn4xu` (workspace ID: `ceff0903-3ad5-4a5b-9e08-ae84db500098`)
- **Health probes**: Liveness (30s) + Startup (10s) on `/api/health:8000`
- **Diagnostic settings**: Container App metrics + PostgreSQL logs/metrics → LAW
- **Alerts**: no-replicas (Sev0), container-restarts (Sev1), postgres-cpu-high (Sev1)
- **Action group**: `ag-bookstore-critical` (needs email/webhook receivers added)
- **Still needed**: Application Insights, zone redundancy, PostgreSQL HA

### Quick Links
- [Team](team.md) — team members
- [Logs & Monitoring](logs.md) — log sources, queries, alerts
- [Architecture doc](knowledge_app-architecture-md.md) — uploaded by Deepthi

### Azure Resources (rg-bookstore-demo, Sweden Central)
- Container App: `ca-bookstore-ixiytoaegn4xu`
- Container App Environment: `cae-ixiytoaegn4xu`
- PostgreSQL: `pg-ixiytoaegn4xu`
- Container Registry: `crixiytoaegn4xu`
- Log Analytics: `law-bookstore-ixiytoaegn4xu`
