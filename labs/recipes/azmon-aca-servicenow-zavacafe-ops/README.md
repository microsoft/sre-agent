# azmon-aca-servicenow-zavacafe-ops

SRE agent for the **Zava Café** demo workload — an ASP.NET app on Azure Container Apps backed by Azure SQL Database. The primary subagent triages SQL performance incidents (DTU spikes, slow queries, blocking chains) end-to-end: diagnose → assess risk → request approval → apply the fix → verify. Two deployment-validator subagents handle post-deploy health checks (Azure DevOps and GitHub Actions paths).

## Stack

- **App** (target workload): .NET 8 / ASP.NET Core (Zava Café e-commerce storefront, sourced from [`labs/zava-cafe/`](../../zava-cafe/))
- **Compute**: Azure Container Apps (or any compute that exposes the workload's metrics + logs to App Insights / LAW)
- **Data**: Azure SQL Database (FQDN + DB name injected into skills via `${AZURE_SQL_SERVER_FQDN}` / `${AZURE_SQL_DATABASE}`)
- **Observability**: Application Insights, Log Analytics, Azure Monitor (alert rules `alert-zavacafe-sql-dtu`, `alert-zavacafe-sql-blocking`, `alert-zavacafe-http-5xx`)
- **SRE Agent**: 3 subagents (`sql-performance-investigator`, `deployment-validator`, `deployment-validator-gh`); 4 skills (`sql-query-diagnosis`, `sql-performance-fix`, `sql-blocking-diagnosis`, `sql-blocking-fix`); 2 hooks (`change-risk-assessor`, `sql-write-guard`); 1 custom Python tool (`AssessChangeRisk`); incident filter `auto-investigate-azmon`; weekly `weekly-cost-report` scheduled task. Connectors: App Insights, Log Analytics, Azure Monitor, ServiceNow, Azure SQL MCP, optional ADO.
- **Simulator**: None — this is the agent half of the lab; pair with [`labs/zava-cafe/`](../../zava-cafe/) (and its `simulate-dtu-spike.ps1` / `simulate-slow-queries.ps1`) for the full break/fix experience
- **CI/CD**: Upstream `sreagent-templates` deployment scripts — `bin/new-agent.sh --recipe ...` → `bin/deploy.sh` → `bin/verify-agent.sh`

## What it's about

This recipe is the **portable, lab-agnostic agent half of [`labs/zava-cafe/`](../../zava-cafe/)** — the SQL-ops + deployment-validation SRE Agent config, packaged in the shape required by [`coreai-microsoft/sreagent-templates`](https://github.com/coreai-microsoft/sreagent-templates) so customers can drop it onto their own ACA + Azure SQL workload without taking the lab's infra or app code. The recipe assumes the workload already exists with App Insights, a Log Analytics workspace, an Azure SQL DB, and the 3 expected alert rules; you supply those resource IDs as parameters and the recipe wires the agent on top.

The recipe targets PMs, SREs, and customers who want to apply Zava Café's SQL break/fix patterns — DTU spike, slow query / missing index, blocking-chain head-blocker analysis, deployment regression rollback — to a real production workload. Demo flow: `bin/new-agent.sh --recipe azmon-aca-servicenow-zavacafe-ops --non-interactive --set ...` → `bin/deploy.sh` → connect ServiceNow as the Incident Platform in the SRE Agent UI → an AzMon alert fires → the `sql-performance-investigator` runs the matching diagnosis + fix skill, scores the change with `AssessChangeRisk`, asks for approval via `AskUserQuestion`, and documents everything in a ServiceNow incident.

## What it does

- **AzMon alert fires** (e.g. `alert-zavacafe-sql-dtu`) → routed to `sql-performance-investigator`
- The subagent runs the right `sql-*-diagnosis` skill, plots a chart, then runs the matching `sql-*-fix` skill
- The fix skill calls `AssessChangeRisk` (a Python tool) to score the change
- The `change-risk-assessor` hook + `sql-write-guard` hook gate destructive ops and force human approval via `AskUserQuestion`
- All work is documented in a ServiceNow incident
- After a release, `deployment-validator` (ADO trigger) or `deployment-validator-gh` (GH Actions trigger) hits `/health`, pulls the commit diff, and rolls back automatically if broken

## Prereqs

- Azure subscription with SRE Agent RP access
- Azure Container Apps environment running the Zava Café workload
- Azure SQL Database (the recipe will inject the FQDN + DB name into skills via `${AZURE_SQL_SERVER_FQDN}` / `${AZURE_SQL_DATABASE}`)
- Application Insights + Log Analytics workspace
- ServiceNow instance (PDI is fine for demos)
- Azure Monitor alert rules created against the workload — at minimum:
  - `alert-zavacafe-sql-dtu` — DTU > 80% for 5 min
  - `alert-zavacafe-sql-blocking` — blocked sessions > 0 for 2 min
  - `alert-zavacafe-http-5xx` — 5xx rate > 1% for 5 min
- (Optional) Azure DevOps org URL + PAT for change-risk pipeline lookups

## Quick start

```bash
./bin/new-agent.sh --recipe azmon-aca-servicenow-zavacafe-ops --non-interactive \
  --set agentName=zavacafe-ops \
  --set resourceGroup=rg-zavacafe-ops \
  --set location=eastus2 \
  --set WORKLOAD_NAME=zava-cafe \
  --set AZURE_RESOURCE_GROUP=rg-zava-cafe \
  --set AZURE_SQL_SERVER_FQDN=sql-zavacafe.database.windows.net \
  --set AZURE_SQL_DATABASE=zava \
  --set ALERT_EMAIL=oncall@example.com \
  --set appInsightsId=/subscriptions/<sub>/resourceGroups/rg-zava-cafe/providers/Microsoft.Insights/components/appi-zavacafe \
  --set appInsightsAppId=<guid> \
  --set lawResourceId=/subscriptions/<sub>/resourceGroups/rg-zava-cafe/providers/Microsoft.OperationalInsights/workspaces/log-zavacafe \
  --set snowInstance=dev123456 \
  --set ADO_ORG_URL=https://dev.azure.com/myorg \
  -o zavacafe-ops/

./bin/deploy.sh zavacafe-ops/
./bin/verify-agent.sh zavacafe-ops/
```

## Parameters

| Param | Required | Example |
|---|---|---|
| `agentName` | ✅ | `zavacafe-ops` |
| `resourceGroup` | ✅ | `rg-zavacafe-ops` |
| `location` | ✅ | `eastus2` |
| `WORKLOAD_NAME` | ⛔ | `zava-cafe` |
| `AZURE_RESOURCE_GROUP` | ✅ | `rg-zava-cafe` |
| `AZURE_SQL_SERVER_FQDN` | ✅ | `sql-zavacafe.database.windows.net` |
| `AZURE_SQL_DATABASE` | ⛔ | `zava` |
| `ALERT_EMAIL` | ✅ | `oncall@example.com` |
| `appInsightsId` | ✅ | App Insights resource ID |
| `appInsightsAppId` | ✅ | App Insights App ID GUID |
| `lawResourceId` | ✅ | Log Analytics workspace resource ID |
| `snowInstance` | ✅ | `dev123456` (PDI subdomain) |
| `ADO_ORG_URL` | ⛔ | Leave blank to skip ADO lookups |

`ADO_PAT` goes in `connectors.secrets.env` — pasted into the agent UI when the AssessChangeRisk tool is first invoked.

## What gets deployed

### Subagents (3)
| Name | Role |
|---|---|
| `sql-performance-investigator` | Primary AzMon-triggered SQL incident handler. Diagnoses + fixes DTU / blocking issues. |
| `deployment-validator` | Post-ADO-release health check + rollback. |
| `deployment-validator-gh` | Post-GitHub-Actions-deploy health check + rollback + PR. |

### Skills (4)
- `sql-query-diagnosis` — slow queries, missing indexes
- `sql-performance-fix` — `CREATE INDEX` / `UPDATE STATISTICS` (gated)
- `sql-blocking-diagnosis` — head-blocker + impact analysis
- `sql-blocking-fix` — `KILL <spid>` (gated)

### Hooks (2)
- `change-risk-assessor` — AI-powered PostToolUse hook that scores SQL writes and forces approval
- `sql-write-guard` — deterministic Python hook that blocks `DROP / DELETE / TRUNCATE / ALTER`

### Tools (1)
- `AssessChangeRisk` — Python tool the fix-skills call before mutating SQL

### Automations
- **Incident filter** `auto-investigate-azmon` — routes the 3 alert rules to `sql-performance-investigator`
- **Scheduled task** `weekly-cost-report` — Mondays 09:00 UTC, summarises last-7-days Azure spend for `${AZURE_RESOURCE_GROUP}`

## Incident Platform setup (post-deploy)

In the SRE Agent UI for the deployed agent:

1. **Builder → Incidents → Connect platform → Azure Monitor** — done automatically by `connectors.json`.
2. **Builder → Incidents → Connect platform → ServiceNow** — enter `https://<snowInstance>.service-now.com` + admin user/password.

## ServiceNow setup

The `sql-performance-investigator` and the deployment-validators write their work-notes to ServiceNow. You need:

- A user account in ServiceNow with `incident_manager` / `itil` role
- The native ServiceNow tools (`CreateServiceNowIncident`, `UpdateServiceNowWorkNotes`, `ResolveServiceNowIncident`, etc.) become available automatically once you connect the Incident Platform.

## Custom tools the agent depends on

The recipe ships `AssessChangeRisk`. The following are **not** in the recipe and must be uploaded via Builder before first run (or they come from the SRE Agent platform once the Incident Platform is connected):

- `CreateServiceNowIncident`, `UpdateServiceNowWorkNotes`, `ResolveServiceNowIncident`, `LookupServiceNowIncident`
- `PlotBarChart`, `PlotPieChart`, `PlotScatter`, `AskUserQuestion` (built-in)
- `zava-mssql_*` MCP tools (the SQL skills depend on a registered Azure SQL MCP server — connect it under Builder → Connectors → MCP)
- `github-mcp.*` (for `deployment-validator-gh`)

## Verifying

```bash
./bin/verify-agent.sh zavacafe-ops/
```

Should report:
- 3 subagents present
- 4 skills present
- 2 hooks present
- 1 custom tool (`AssessChangeRisk`)
- 1 scheduled task (`weekly-cost-report`)
- 1 incident filter (`auto-investigate-azmon`)
- Connectors: app-insights, log-analytics, azure-monitor

## Cost

Monthly Agent Unit cap = 15000 in `agent.json`. Tune based on incident + release volume.
