# Azure Monitor Alert Noise Filter + ServiceNow Ticket Recipe

## Overview

This recipe reduces alert noise by filtering transient Azure Monitor alerts before they become ServiceNow tickets:

1. **Azure Monitor alert fires** → routed to the **Alert Triage Agent**
2. **15-minute transient check** — the triage agent runs Python code to wait 15 minutes, then re-checks whether the alert is still in Fired state
3. **Transient alert** (resolved within 15 min) → closed automatically with a summary. No ticket created.
4. **Persistent alert** (still firing after 15 min) → escalated to the **Alert Investigator** for deep analysis
5. **Investigation** — correlates App Insights, Log Analytics, Azure Monitor metrics, and Activity Logs to find root cause
6. **ServiceNow ticket** — creates an incident in ServiceNow via MCP with full investigation details

## Architecture

```
Azure Monitor Alert (Fired)
        │
        ▼
┌─────────────────────┐
│  Alert Triage Agent  │
│  (15-min timer)      │
└────────┬────────────┘
         │
    ┌────┴────┐
    │         │
Resolved   Still Fired
    │         │
    ▼         ▼
 Close    ┌──────────────────┐
 Alert    │ Alert Investigator │
          │ (deep analysis)    │
          └────────┬───────────┘
                   │
                   ▼
          ┌─────────────────┐
          │ ServiceNow MCP   │
          │ (create ticket)  │
          └─────────────────┘
```

## Data Sources

| Source | Purpose |
|---|---|
| Azure Monitor | Alert ingestion (incident platform), metric queries |
| Application Insights | Exception traces, failed requests, dependencies |
| Log Analytics | Correlated logs, custom queries |
| ServiceNow (MCP connector) | Incident ticket creation/update via `sn_mcp` server |

## Prerequisites

- Azure subscription with resource groups to monitor
- Application Insights and/or Log Analytics workspace (recommended)
- ServiceNow instance with MCP server enabled (`sn_mcp` plugin)
- ServiceNow user with incident create/update permissions

## Quick Start

```bash
# Set required environment variables
azd env set RECIPE azmon-servicenow-transient-check
azd env set AZURE_AGENT_NAME my-alert-triage-agent
azd env set AZURE_RESOURCE_GROUP sre-agent-rg
azd env set AZURE_LOCATION swedencentral
azd env set AZURE_TARGET_RGS "rg-app-prod,rg-db-prod"

# Optional: App Insights / LAW
azd env set AZURE_AI_ID /subscriptions/.../applicationInsights/my-ai
azd env set AZURE_AI_APPID <guid>
azd env set AZURE_LAW_ID /subscriptions/.../workspaces/my-law

# Deploy
azd up
```

Then configure the ServiceNow MCP connector in the portal with your instance credentials.

## Subagents

| Agent | Role |
|---|---|
| `alert-triage-agent` | First responder. Runs 15-min transient check. Routes alerts. |
| `alert-investigator` | Deep investigation. Creates ServiceNow tickets. |

## Skills

| Skill | Purpose |
|---|---|
| `transient-alert-checker` | Python timer + alert state re-check after 15 minutes |
| `investigate-persistent-alert` | Full investigation + ServiceNow ticket creation |
