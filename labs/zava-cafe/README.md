# Zava — Zava Café SRE Agent Lab

A realistic e-commerce platform (Zava) running on Azure App Service + Azure SQL
DB. The lab is wired up so that we can break the SQL DB or the web tier on
purpose and watch an Azure SRE Agent investigate, diagnose, and (with the right
hooks) remediate the issue.

This lab focuses purely on the SQL/DevOps ops scenarios. The IT-support /
laptop-replacement story has moved to its own standalone lab at
[`../zava-itsupport/`](../zava-itsupport/).

## Stack

- **App**: .NET 8 / ASP.NET Core — Zava Café specialty coffee e-commerce storefront (espresso, brewed coffee, pastries, merch)
- **Compute**: Azure App Service (P0v3 Linux App Service Plan)
- **Data**: Azure SQL Database (Basic, 5 DTU) — intentionally tiny so DTU spikes are easy to trigger; seeded from `infra/seed-database.sql`
- **Observability**: Log Analytics + Application Insights + Azure Portal Dashboard + 3 metric alert rules (SQL DTU > 80%, App Service HTTP 5xx > 5/5min, App Service health-check < 100%)
- **SRE Agent**: `sre-agent-zava-cafe-<token>` — single workspace with the `agent1` config: subagents `sql-performance-investigator`, `deployment-validator`, `deployment-validator-gh`; skills for blocking-chain and slow-query diagnosis/fix; hooks `sql-write-guard` + `change-risk-assessor`; tool `AssessChangeRisk`; weekly cost-report scheduled task
- **Simulator**: PowerShell scenario runners under `sre-config/` (`simulate-dtu-spike.ps1`, `simulate-slow-queries.ps1`)
- **CI/CD**: `azd up` (sub-scope Bicep → RG-scope Bicep → seed SQL → deploy .NET source → `srectl apply`)

## What it's about

The Zava Café lab is for PMs, SREs, and customers who want to see the **Azure SRE Agent investigate and remediate Azure SQL performance incidents** end-to-end on a realistic e-commerce workload. Zava Café is a fictional specialty coffee shop running its storefront on App Service backed by a deliberately small Azure SQL DB — so a couple of bad queries reliably spike DTU, miss indexes, or chain blocking sessions. The lab teaches break/fix patterns around DTU exhaustion, missing indexes / slow queries, blocking chains, and post-deploy regression validation, while also showing the safety story (write-guard hook + AI change-risk assessor + human-in-the-loop approval).

Demo flow: `azd up` provisions infra, deploys the .NET app, and registers the SRE Agent workspace via `srectl`. From there, run `pwsh sre-config/simulate-dtu-spike.ps1` (or `simulate-slow-queries.ps1`) to fault the DB → an Azure Monitor alert fires → the agent picks up the incident, runs the matching `sql-*-diagnosis` skill, plots a chart, asks the user to approve the fix, and applies it. The same agent's `deployment-validator` subagents handle post-release health checks (ADO and GitHub Actions paths) and roll back automatically on regression.

A single SRE Agent workspace is deployed:

- **agent1** — SQL/DevOps: `sql-performance-investigator`,
  `deployment-validator`, `deployment-validator-gh`. Skills cover
  blocking-chain diagnosis/fix, slow-query diagnosis/fix. Includes a write
  guard hook (`sql-write-guard`) and a change-risk-assessor hook backed by the
  `AssessChangeRisk` Python tool. A weekly cost-report scheduled task is
  registered.

## Architecture (text sketch)

```
        ┌──────────────────────────────┐
        │  Azure SRE Agent (autonomous)│
        │  + agent1 workspace          │
        └──────────────┬───────────────┘
                       │ alerts (DTU, 5xx, health-check)
        ┌──────────────┴───────────────┐
        │      Azure Monitor           │
        └──┬───────────────────────────┘
           │
   ┌───────┴──┐
   │ Zava .NET│
   │ (App Svc)│
   └────┬─────┘
        │
   ┌────┴──────────────┐
   │ Azure SQL DB (B5) │
   └───────────────────┘
```

## Quick start

```pwsh
# 1. Install azd if needed
winget install Microsoft.Azd

# 2. Login + pick a subscription
az login
azd auth login

# 3. (Optional) Override the SQL admin password — otherwise one is generated
azd env set SQL_ADMIN_PASSWORD "<your strong password>"

# 4. Deploy via the Zava launcher
pwsh ../lab.ps1 -Labs zava-cafe
```

The launcher invokes `azd up`, which:

1. Runs `scripts/prereqs.sh` (preprovision hook) to verify tools and stash a
   SQL password into the azd env.
2. Provisions infra via `infra/main.bicep` (sub-scope) →
   `infra/resources.bicep` (RG-scope).
3. Runs `scripts/post-provision.sh`, which seeds SQL, deploys the .NET web
   app from source, then registers the SRE Agent workspace with `srectl`
   and fires a smoke-test thread.

## Scenarios

| id | runner | what it does |
|---|---|---|
| `dtu-spike` | `sre-config/simulate-dtu-spike.ps1` | Floods SQL with heavy queries → DTU > 80% → alert → agent investigates |
| `slow-queries` | `sre-config/simulate-slow-queries.ps1` | Generates a flood of slow queries → agent recommends an index |

## What gets deployed

- **Azure SQL Server + DB** (Basic 5 DTU) — intentionally small so the demos
  spike easily. Seeded from `infra/seed-database.sql`.
- **App Service Plan** (P0v3 Linux) hosting:
  - Zava main app (.NET 8, `src/`)
- **Log Analytics + App Insights** (linked) for telemetry.
- **3 metric alert rules**: SQL DTU > 80%, App Service HTTP 5xx > 5/5min,
  App Service health-check < 100%.
- **Azure Portal Dashboard** with key metrics.
- **User-Assigned Managed Identity** with subscription-scoped Reader +
  Monitoring + Log Analytics + Container Apps Contributor roles.
- **Azure SRE Agent** (`sre-agent-zava-cafe-<token>`) wired to the App
  Insights workspace, with `sre-config/agent1` resources registered via
  `srectl` in the post-provision hook.

## Skipping the srectl block

Set `LABS_SKIP_SRECTL=1` before `azd up` (or before re-running
`bash scripts/post-provision.sh`) to skip agent registration entirely.
