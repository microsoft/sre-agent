# PowerGrid Utility Portal — Architecture

## Overview

PowerGrid is a utility management portal deployed on **Azure Container Apps**. It provides outage reporting, meter reading, grid status monitoring, and customer notifications for a fictional power utility company. It serves as the monitored application for the SRE Agent ZeroOps lab.

---

## Architecture Diagram

```
                        ┌─────────────────────────────────┐
                        │         Azure Front Door /       │
                        │         External Ingress         │
                        └──────────┬──────────────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │       portal-web             │
                    │   (React/Vite on nginx)      │
                    │   Port 80 — Static SPA       │
                    └──┬───────┬────────┬────────┬─┘
                       │       │        │        │
          ┌────────────▼┐  ┌──▼─────┐ ┌▼──────┐ ┌▼──────────────┐
          │ outage-api   │  │meter-  │ │grid-  │ │notification-  │
          │ Python/Flask │  │api     │ │status-│ │svc            │
          │ Port 5000    │  │.NET 8  │ │api    │ │Go             │
          │              │  │Port 80 │ │Node.js│ │Port 8080      │
          └──────┬───────┘  └──┬─────┘ │Expr.  │ └───────┬───────┘
                 │             │       │P 3000 │         │
                 │             │       └──┬────┘         │
                 ▼             ▼          ▼              ▼
          ┌──────────────────────────────────────────────────┐
          │              Azure SQL Database                   │
          │         (shared, Managed Identity auth)          │
          └──────────────────────────────────────────────────┘
                 │             │          │              │
                 ▼             ▼          ▼              ▼
          ┌──────────────────────────────────────────────────┐
          │         Azure Container Apps Environment          │
          │    ┌─────────────────────────────────────────┐   │
          │    │   Log Analytics Workspace (Console Logs) │   │
          │    │   Application Insights (Telemetry)       │   │
          │    │   Azure Managed Grafana (Dashboards)      │   │
          │    └─────────────────────────────────────────┘   │
          └──────────────────────────────────────────────────┘
```

---

## Infrastructure

| Component | Azure Service | Details |
|-----------|---------------|---------|
| **portal-web** | Azure Container Apps | React/Vite SPA served by nginx, port 80, external ingress |
| **outage-api** | Azure Container Apps | Python/Flask API, port 5000, internal ingress |
| **meter-api** | Azure Container Apps | .NET 8 Web API, port 80, internal ingress |
| **grid-status-api** | Azure Container Apps | Node.js/Express API, port 3000, internal ingress |
| **notification-svc** | Azure Container Apps | Go service, port 8080, internal ingress |
| **Database** | Azure SQL Database | Shared database, Managed Identity authentication |
| **Cache** | Azure Cache for Redis | Optional — session/rate-limit caching |
| **Container Registry** | Azure Container Registry | Private registry, Managed Identity pull |
| **Logs** | Log Analytics Workspace | Console logs via `ContainerAppConsoleLogs_CL` |
| **Telemetry** | Application Insights | Request metrics, exceptions, dependencies |
| **Dashboards** | Azure Managed Grafana | Pre-built dashboards for all services |
| **Identity** | User-Assigned Managed Identity | All services authenticate via MI — no secrets in code |
| **Alerts** | Azure Monitor | Metric alerts for HTTP 5xx, latency, OOM, restarts |

---

## Microservices Detail

### 1. portal-web (React/Vite on nginx)

**Container App Name:** `ca-powergrid-portal`

| Endpoint | Method | Description | Expected Response |
|----------|--------|-------------|-------------------|
| `/` | GET | SPA entry point | 200 — HTML |
| `/health` | GET | nginx health check | 200 |

**Resources:** 0.25 CPU, 0.5 Gi memory | Min replicas: 1, Max: 3

---

### 2. outage-api (Python/Flask)

**Container App Name:** `ca-powergrid-outage`

| Endpoint | Method | Description | Expected Response |
|----------|--------|-------------|-------------------|
| `/health` | GET | Health check | 200 `{"status": "healthy"}` |
| `/api/outages` | GET | List active outages | 200 `[{outage objects}]` |
| `/api/outages` | POST | Report new outage | 201 `{outage object}` |
| `/api/outages/{id}` | GET | Get outage by ID | 200 / 404 |
| `/api/outages/{id}/status` | PUT | Update outage status | 200 / 404 |

**Resources:** 0.5 CPU, 1 Gi memory | Min replicas: 1, Max: 5

---

### 3. meter-api (.NET 8)

**Container App Name:** `ca-powergrid-meter`

| Endpoint | Method | Description | Expected Response |
|----------|--------|-------------|-------------------|
| `/health` | GET | Health check | 200 `Healthy` |
| `/api/meters` | GET | List all meters | 200 `[{meter objects}]` |
| `/api/meters/{id}` | GET | Get meter by ID | 200 / 404 |
| `/api/meters/{id}/readings` | GET | Get meter readings | 200 `[{reading objects}]` |
| `/api/meters/{id}/readings` | POST | Submit meter reading | 201 |

**Resources:** 0.5 CPU, 1 Gi memory | Min replicas: 1, Max: 5

---

### 4. grid-status-api (Node.js/Express)

**Container App Name:** `ca-powergrid-grid`

| Endpoint | Method | Description | Expected Response |
|----------|--------|-------------|-------------------|
| `/health` | GET | Health check | 200 `{"status": "ok"}` |
| `/api/grid/status` | GET | Current grid status | 200 `{grid status object}` |
| `/api/grid/regions` | GET | Status by region | 200 `[{region objects}]` |
| `/api/grid/regions/{id}` | GET | Single region status | 200 / 404 |
| `/api/grid/history` | GET | Historical grid data | 200 `[{history objects}]` |

**Resources:** 0.5 CPU, 1 Gi memory | Min replicas: 1, Max: 5

---

### 5. notification-svc (Go)

**Container App Name:** `ca-powergrid-notify`

| Endpoint | Method | Description | Expected Response |
|----------|--------|-------------|-------------------|
| `/health` | GET | Health check | 200 `{"status": "ok"}` |
| `/api/notifications/send` | POST | Send notification | 202 `{notification ID}` |
| `/api/notifications/{id}` | GET | Get notification status | 200 / 404 |
| `/api/notifications/subscribe` | POST | Subscribe to alerts | 201 |

**Resources:** 0.25 CPU, 0.5 Gi memory | Min replicas: 1, Max: 3

---

## Naming Convention

All resources follow a consistent naming pattern:

| Resource Type | Pattern | Example |
|---------------|---------|---------|
| Resource Group | `rg-powergrid-{env}` | `rg-powergrid-dev` |
| Container App | `ca-powergrid-{service}` | `ca-powergrid-outage` |
| Container App Environment | `cae-powergrid-{env}` | `cae-powergrid-dev` |
| Log Analytics | `log-powergrid-{env}` | `log-powergrid-dev` |
| App Insights | `appi-powergrid-{env}` | `appi-powergrid-dev` |
| SQL Server | `sql-powergrid-{env}` | `sql-powergrid-dev` |
| SQL Database | `sqldb-powergrid` | `sqldb-powergrid` |
| Container Registry | `crpowergrid{env}` | `crpowergriddev` |

---

## Monitoring & Alerting

### Key KQL Queries

**All service errors (last hour):**
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(1h)
| where Log_s contains "error" or Log_s contains "Error" or Log_s contains "500" or Log_s contains "503"
| summarize ErrorCount = count() by ContainerAppName_s, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

**Service health overview:**
```kql
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(15m)
| summarize
    TotalLogs = count(),
    Errors = countif(Log_s contains "error" or Log_s contains "Error"),
    Warnings = countif(Log_s contains "warn" or Log_s contains "Warning")
by ContainerAppName_s
| extend ErrorRate = round(100.0 * Errors / TotalLogs, 2)
| order by ErrorRate desc
```

### Alert Rules

| Alert | Trigger | Severity | Services |
|-------|---------|----------|----------|
| HTTP 5xx errors | > 5 requests with 5xx in 5 min | Sev2 | All APIs |
| Container OOM restart | RestartCount > 0 in 5 min | Sev2 | meter-api |
| High latency | Avg response > 5s for 5 min | Sev3 | grid-status-api |
| Container crash loop | > 3 restarts in 10 min | Sev1 | notification-svc |

---

## Known Fault Injection Mechanisms

| Service | Env Var | Effect | Symptom |
|---------|---------|--------|---------|
| outage-api | `FORCE_ERROR=true` | Returns 503 on all endpoints | HTTP 503, error logs |
| meter-api | `SIMULATE_OOM=true` | Triggers memory leak → OOM kill | High memory, restarts |
| grid-status-api | `SIMULATE_DELAY_MS=<ms>` | Adds artificial latency | Slow responses, timeouts |
| notification-svc | Missing `REQUIRED_CONFIG` | Crashes on startup | CrashLoopBackOff, no logs |

---

## Troubleshooting Quick Reference

1. **Check all services:** `az containerapp list -g <rg> -o table`
2. **Check specific service:** `az containerapp show -g <rg> -n <app-name>`
3. **Get logs:** `az containerapp logs show -g <rg> -n <app-name> --tail 300`
4. **List revisions:** `az containerapp revision list -g <rg> -n <app-name> -o table`
5. **Check env vars:** `az containerapp show -g <rg> -n <app-name> --query "properties.template.containers[0].env"`
6. **Restart:** `az containerapp revision restart -g <rg> -n <app-name> --revision <rev>`
