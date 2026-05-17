# azmon-aca-servicenow-zavapower-ops

Production-ops SRE agent for **Zava Power**'s microservices platform on Azure Container Apps. Handles 5xx alerts, latency, container restarts, deployment validation, VM disk pressure, pipeline failures, and pod fleet audits — across 5 services. Native Azure Monitor + ServiceNow incident platforms; optional Datadog and Dynatrace MCP connectors.

## Stack

- **App** (target workload): 5-service microservices fleet — Python/Flask, .NET 8, Node.js 20, Go 1.22, React (sourced from [`labs/zava-power/`](../../zava-power/))
- **Compute**: Azure Container Apps (recipe is parameterized on `containerAppPrefix` + `targetRGs`)
- **Data**: None (microservices are stateless; ServiceNow PDI is the system of record for tickets)
- **Observability**: Application Insights, Log Analytics (`ContainerAppConsoleLogs`), Azure Monitor; optional Datadog and Dynatrace MCP connectors
- **SRE Agent**: 8 subagents (`incident-handler`, `deployment-validator`, `vm-ops-agent`, `utility-ops-agent`, `web-app-troubleshooter`, `pod-incident-remediator`, `release-orchestrator`, `pipeline-failure-investigator`); 15 skills (per-service diagnosis + crash/config/perf classes + ops procedures); incident filter `auto-investigate-azmon`; daily `pod-fleet-audit-daily` scheduled task. Connectors: App Insights, Log Analytics, Azure Monitor, ServiceNow, optional Datadog/Dynatrace.
- **Simulator**: None — pair with [`labs/zava-power/simulator/demo.py`](../../zava-power/simulator/) for the full 7-scenario break/fix experience
- **CI/CD**: Upstream `sreagent-templates` deployment scripts — `bin/new-agent.sh --recipe ...` → `bin/deploy.sh` → `bin/verify-agent.sh`

## What it's about

This recipe is the **portable, lab-agnostic agent half of [`labs/zava-power/`](../../zava-power/)** — the production-ops SRE Agent config for a multi-language microservices fleet on Azure Container Apps, packaged in the shape required by [`coreai-microsoft/sreagent-templates`](https://github.com/coreai-microsoft/sreagent-templates) so customers can drop it onto their own ACA workload without the lab's infra or simulator. The recipe assumes the workload already exists with App Insights, a Log Analytics workspace, AzMon alert rules, and a ServiceNow PDI; you supply those resource IDs as parameters and the recipe wires the agent on top.

The recipe targets PMs, SREs, and customers who want to apply Zava Power's break/fix patterns — 5xx investigations, perf regressions, container restarts, VM disk pressure (Azure Arc), ADO pipeline failures, post-rollout validation, daily fleet audit decks — to their own ACA fleet. Demo flow: `bin/new-agent.sh --recipe azmon-aca-servicenow-zavapower-ops --non-interactive --set ...` → `bin/deploy.sh` → connect ServiceNow as the Incident Platform in the SRE Agent UI → an AzMon alert fires → the `incident-handler` (or the right specialist subagent) opens a ServiceNow incident, investigates, remediates, and documents the work.

## Quick start

```bash
./bin/new-agent.sh --recipe azmon-aca-servicenow-zavapower-ops --non-interactive \
  --set agentName=zavapower-ops \
  --set resourceGroup=rg-zavapower-ops \
  --set location=eastus2 \
  --set targetRGs=rg-zavapower-prod \
  --set appInsightsId=/subscriptions/<sub>/resourceGroups/rg-zavapower-prod/providers/Microsoft.Insights/components/appi-zavapower \
  --set appInsightsAppId=<guid> \
  --set lawResourceId=/subscriptions/<sub>/resourceGroups/rg-zavapower-prod/providers/Microsoft.OperationalInsights/workspaces/log-zavapower \
  --set snowInstance=dev123456 \
  --set containerAppPrefix=powergrid \
  --set workloadName=zavapower \
  -o zavapower-ops/

./bin/deploy.sh zavapower-ops/
./bin/verify-agent.sh zavapower-ops/
```

## Parameters

| Param | Required | Example |
|---|---|---|
| `agentName` | ✅ | `zavapower-ops` |
| `resourceGroup` | ✅ | `rg-zavapower-ops` |
| `location` | ✅ | `eastus2` |
| `targetRGs` | ✅ | `rg-zavapower-prod` |
| `appInsightsId` | ✅ | `/subscriptions/.../components/appi-zavapower` |
| `appInsightsAppId` | ✅ | App Insights App ID GUID |
| `lawResourceId` | ✅ | Log Analytics workspace resource ID |
| `snowInstance` | ✅ | `dev123456` (PDI subdomain) |
| `containerAppPrefix` | ⛔ | `powergrid` |
| `workloadName` | ⛔ | `zavapower` |
| `datadogApiKey` | ⛔ | leave blank to skip Datadog |
| `dynatraceTenantUrl` | ⛔ | leave blank to skip Dynatrace |

## What gets deployed

### Connectors
- App Insights (workload telemetry)
- Log Analytics (`ContainerAppConsoleLogs`)
- Azure Monitor (alert routing)
- Datadog MCP (optional)
- Dynatrace MCP (optional)
- ServiceNow Incident Platform (configured via UI after deploy)

### Subagents (8)
| Name | Role |
|---|---|
| `incident-handler` | Primary 5xx / latency / restart investigator. Documents to ServiceNow. |
| `deployment-validator` | Validates a rollout against alert noise & error baseline. |
| `vm-ops-agent` | Disk pressure & VM-level remediation (Azure Arc / VMs). |
| `utility-ops-agent` | Daily fleet audit deck — read-only, report-only. |
| `web-app-troubleshooter` | App Service / front-end specific path. |
| `pod-incident-remediator` | ACA-replica-level remediation (restarts, scale-out). |
| `release-orchestrator` | Pipeline → SRE → release flow coordinator. |
| `pipeline-failure-investigator` | ADO build/release failure diagnosis. |

### Skills (15)
Service-specific diagnosis skills (`outage-api-diagnosis`, `meter-api-diagnosis`, …), classes of regression (`crash-`, `config-`, `perf-`), and ops procedures (`deployment-rollback`, `deployment-validation`, `repo-routing`, `release-on-sre-fix`, `pod-fleet-audit-deck`, `plot-incident-metrics`, `disk-pressure-diagnosis`, `sre-agent-customizer`).

### Automations
- **Incident filter** `auto-investigate-azmon` — routes the 3 ACA alert rules to `incident-handler`
- **Scheduled task** `pod-fleet-audit-daily` — 8 AM UTC daily, runs `utility-ops-agent` to produce a .pptx deck

## Incident Platform setup (post-deploy)

In the SRE Agent UI for the deployed agent:

1. **Builder → Incidents → Connect platform → Azure Monitor** → done automatically by `connectors.json`.
2. **Builder → Incidents → Connect platform → ServiceNow** → enter `https://<snowInstance>.service-now.com` + creds.

## Custom tools the agent depends on

The recipe references these tool names but does not ship them. They are part of the lab and must be uploaded via Builder before the agent runs:

- `CreateServiceNowIncident`, `UpdateServiceNowWorkNotes`, `LookupServiceNowIncident`
- `UploadChartToServiceNow`, `UploadDeckToServiceNow`, `UploadServiceNowAttachment`
- `GenerateAuditDeck`, `PythonChartGenerator`, `PythonScriptRunner`
- `RunAzCliReadCommands`, `RunAzCliWriteCommands` (provided by SRE Agent platform)
- `GetADOBuildDetails`, `GetADOReleaseDetails`, `RestartADOBuild` (if ADO integration enabled)

See `labs/zava-power/sre-config/tools/` for the source YAMLs.

## Verifying

```bash
./bin/verify-agent.sh zavapower-ops/
```

Should report:
- 8 subagents present
- 15 skills present
- 1 scheduled task
- 1 incident filter (`auto-investigate-azmon`)
- Connectors: app-insights, log-analytics, azure-monitor (datadog/dynatrace if their params were set)

## Cost

Higher than the IT-support recipe — incidents fan out to multiple subagents. Default monthly Agent Unit cap = 25000. Tune in `agent.json` based on incident volume.
