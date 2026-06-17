# Enterprise App Architecture Reference

## Overview

This document describes the enterprise demo application: a Node.js API backed by PostgreSQL, running on a private AKS cluster with all monitoring routed through Azure Monitor Private Link Scope (AMPLS).

## Components

### Application Tier — AKS (Private Cluster)
- Private AKS cluster — API server has no public endpoint
- Node.js Express API serving /api/orders, /api/products, /api/health
- Application Insights SDK integrated for request telemetry
- All kubectl operations require `az aks command invoke` (ARM proxy)
- Namespace: default

### Data Tier — PostgreSQL Flexible Server
- PostgreSQL 16, VNet-delegated subnet (no public access)
- Database: enterprise_db
- Tables: products, orders
- Entra auth or password auth depending on deployment
- Connection from app pods goes through VNet-internal routing

### Networking
- **VNet**: Single VNet with three subnets
  - `aks-subnet` (10.0.0.0/16) — AKS nodes and pods
  - `db-subnet` (10.1.0.0/24) — PostgreSQL (delegated)
  - `ampls-subnet` (10.2.0.0/24) — Private endpoint for AMPLS
- **NSG**: On AKS subnet, allow-all-outbound baseline
- **Private DNS Zones**: PostgreSQL + Azure Monitor (monitor, oms, ods, agentsvc)

### Monitoring — AMPLS (Azure Monitor Private Link Scope)
- **App Insights**: Ingestion and query both set to PrivateOnly
- **Log Analytics**: Ingestion and query both set to PrivateOnly
- **AMPLS**: Links both AI and LAW, with a private endpoint in ampls-subnet
- **Private DNS Zones**: Four zones (privatelink.monitor.azure.com, privatelink.oms.opinsights.azure.com, privatelink.ods.opinsights.azure.com, privatelink.agentsvc.azure-automation.net) linked to the VNet
- All telemetry from AKS pods flows through the private endpoint — no public ingestion
- Alert rule: `app-5xx-errors` fires on requests/failed > 5 (auto-mitigate enabled)

### Incident Management — ServiceNow
- P1/P2 incidents from ServiceNow route to the azure-monitor-investigator subagent
- Agent operates in Autonomous mode with merge window of 1 hour
- Hooks require approval for writes and block deletes

## Request Flow

```
Client → AKS Ingress → enterprise-api pod → PostgreSQL (private)
                           ↓
                    App Insights SDK
                           ↓
                    AMPLS Private Endpoint
                           ↓
                    Log Analytics Workspace
```

## Failure Modes

| Failure | Symptom | How to detect | How to fix |
|---|---|---|---|
| PostgreSQL stopped | 500 on /api/orders, /api/health returns unhealthy | `az postgres flexible-server show --query state` | `az postgres flexible-server start` |
| PostgreSQL connection refused | 500 with ECONNREFUSED | App Insights dependency failures | Check NSG rules, VNet delegation |
| Pod crash loop | 502 from ingress | `az aks command invoke -- kubectl get pods` | Check logs, restart deployment |
| Slow queries | High latency on /api/products | App Insights request duration | Check missing indexes, ANALYZE |
| AMPLS misconfigured | No telemetry flowing | Check AI ingestion in portal | Verify private endpoint + DNS zones |

## Access Patterns for the SRE Agent

The agent is outside the VNet. All access is through the Azure control plane:

| Resource | Read | Remediate |
|---|---|---|
| AKS | `az aks command invoke -- kubectl get/logs/describe` | `az aks command invoke -- kubectl delete/rollout restart` |
| PostgreSQL | `az postgres flexible-server show/list` | `az postgres flexible-server start/restart` |
| App Insights | Built-in connector (private query via AMPLS) | N/A (read-only) |
| Log Analytics | Built-in connector (private query via AMPLS) | N/A (read-only) |
| Activity Logs | KQL via LAW | N/A (read-only) |
