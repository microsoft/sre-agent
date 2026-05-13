# azmon-aca-servicenow-zavaitsupport

> **Unified IT-support recipe.** This is the single canonical recipe for the
> ServiceNow IT-support / laptop-replacement agent. It supersedes the prior
> `azmon-aca-servicenow-azurefriday-itsupport` and
> `azmon-aca-servicenow-zavapower-itsupport` recipes, which have been removed.
> The agent and tools here are sourced from
> [`labs/zava-itsupport/sre-config/`](../../zava-itsupport/sre-config/).

ServiceNow IT-support helpdesk agent for the **Zava IT Support** Zava demo. Polls ServiceNow for laptop-replacement requests, validates warranty via a custom Python tool against the lab's warranty API, submits a replacement order through Browser Operator, and resolves the SNOW ticket — fully autonomous.

## Stack

- **App** (target workload): Node.js 20 IT-portal + Python 3.11 / FastAPI warranty API (sourced from [`labs/zava-itsupport/`](../../zava-itsupport/))
- **Compute**: Azure Container Apps (recipe is workload-agnostic — only requires the warranty API to be reachable at `${WARRANTY_API_URL}`)
- **Data**: None (warranty data is mocked in the warranty-tool service; ServiceNow PDI is the system of record for tickets)
- **Observability**: ServiceNow incident telemetry only (no AzMon dependency in this recipe)
- **SRE Agent**: 1 subagent (`it-support-handler`, autonomous); 2 custom Python tools (`CheckWarranty`, `LookupServiceNowIncident`) shipped in `config/tools/`; incident filter `snow-laptop-replacement` (categoryFilter=hardware, shortDescriptionContains=laptop, priorities 3/4/5). Connectors: ServiceNow Incident Platform; native ServiceNow tools (`GetServiceNowIncident`, `PostServiceNowDiscussionEntry`, `AcknowledgeServiceNowIncident`, `ResolveServiceNowIncident`) become available after platform connection; Browser Operator for portal submission; `SendOutlookEmail` for employee notifications. No skills, no hooks, no scheduled tasks — single-purpose automation.
- **Simulator**: None — pair with [`labs/zava-itsupport/scripts/laptop-request-demo.sh`](../../zava-itsupport/scripts/) to file a sample request
- **CI/CD**: Upstream `sreagent-templates` deployment scripts — `bin/new-agent.sh --recipe ...` → `bin/deploy.sh`

## What it's about

This recipe is the **portable, lab-agnostic agent half of [`labs/zava-itsupport/`](../../zava-itsupport/)** — the ServiceNow IT-support / laptop-replacement SRE Agent config, packaged in the shape required by [`coreai-microsoft/sreagent-templates`](https://github.com/coreai-microsoft/sreagent-templates) so customers can drop it onto their own ServiceNow + warranty-API setup without taking the lab's infra or app code. It is the unified, canonical IT-support recipe — superseding the prior `azmon-aca-servicenow-azurefriday-itsupport` and `azmon-aca-servicenow-zavapower-itsupport` recipes.

The recipe targets PMs, SREs, and customers who want to see the SRE Agent automate a **ServiceNow-driven helpdesk workflow with custom Python tools** — distinct from the AzMon-driven infrastructure-ops recipes. The break/fix pattern is single-purpose: a hardware/laptop SNOW ticket arrives → the filter routes to `it-support-handler` → the agent calls `LookupServiceNowIncident` to fetch the ticket → calls `CheckWarranty` against the warranty API → if eligible, submits a replacement via Browser Operator and resolves the ticket; if not, posts a discussion entry explaining next steps. Demo flow: `bin/new-agent.sh --recipe azmon-aca-servicenow-zavaitsupport ...` → `bin/deploy.sh` → connect ServiceNow as the Incident Platform → create a SNOW incident with category=Hardware + "Laptop replacement request" → watch the agent run the workflow autonomously.

## What it does

1. A ServiceNow incident with category=`hardware` and short_description containing `laptop` is created.
2. The `snow-laptop-replacement` filter routes it to `it-support-handler`.
3. The agent calls `LookupServiceNowIncident` (custom tool) to fetch ticket details by INC number.
4. The agent calls `CheckWarranty` (custom tool, hits `${WARRANTY_API_URL}`) with the device serial number.
5. If eligible, the agent uses Browser Operator to file a laptop request, then resolves the SNOW ticket and emails the employee.
6. If not eligible, the agent posts a discussion entry explaining next steps and resolves the ticket.

## Prereqs

- Azure subscription with SRE Agent RP access
- ServiceNow instance (PDI works) — reachable from the agent
- ServiceNow admin user with `incident_manager` / `itil` role
- The lab's warranty API reachable at `${WARRANTY_API_URL}` (returns JSON like `{ "found": true, "eligible_for_replacement": true, "warranty_expiry": "...", "recommended_replacement": "Dell XPS 15 9530" }`)

## Quick start

```bash
./bin/new-agent.sh --recipe azmon-aca-servicenow-zavaitsupport-itsupport --non-interactive \
  --set agentName=zavaitsupport-itsupport \
  --set resourceGroup=rg-zavaitsupport-itsupport \
  --set location=eastus2 \
  --set WORKLOAD_NAME=zava-itsupport \
  --set WARRANTY_API_URL=https://app-zava-warranty.azurewebsites.net \
  --set SERVICENOW_INSTANCE_URL=https://dev123456.service-now.com \
  --set SERVICENOW_USERNAME=admin \
  --set demoEmployeeEmail=demo.user@zavaitsupport.com \
  -o zavaitsupport-itsupport/

./bin/deploy.sh zavaitsupport-itsupport/
```

`SERVICENOW_PASSWORD` is supplied via the SRE Agent UI when the Incident Platform is connected (and is also pasted into the `LookupServiceNowIncident` tool's secret slot on first invocation).

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| `agentName` | ✅ | `zavaitsupport-itsupport` | You choose (lowercase, hyphens) |
| `resourceGroup` | ✅ | `rg-zavaitsupport-itsupport` | You choose or use existing RG |
| `location` | ✅ | `eastus2` | Where to host the agent |
| `WORKLOAD_NAME` | ⛔ | `zava-itsupport` | Workload tag |
| `WARRANTY_API_URL` | ⛔ | `https://app-zava-warranty.azurewebsites.net` | Lab's warranty service endpoint |
| `SERVICENOW_INSTANCE_URL` | ✅ | `https://dev123456.service-now.com` | ServiceNow instance URL |
| `SERVICENOW_USERNAME` | ⛔ | `admin` | ServiceNow user the LookupServiceNowIncident tool authenticates as |
| `demoEmployeeEmail` | ⛔ | `demo.user@zavaitsupport.com` | Fallback email when not in the ticket |

## What gets deployed

- **Subagent:** `it-support-handler` (Autonomous, native ServiceNow tools + `CheckWarranty` + `LookupServiceNowIncident` + `SendOutlookEmail`)
- **Tools:** `CheckWarranty`, `LookupServiceNowIncident` (custom Python tools, shipped in `config/tools/`)
- **Incident platform:** ServiceNow
- **Incident filter:** `snow-laptop-replacement` — routes hardware/laptop tickets to the handler
- No skills, no hooks, no scheduled tasks — single-purpose automation

## ServiceNow setup (post-deploy)

In the SRE Agent UI for the deployed agent:

1. **Builder → Incidents → Connect platform → ServiceNow**
2. Instance URL: `${SERVICENOW_INSTANCE_URL}`
3. Username: `${SERVICENOW_USERNAME}`
4. Password: (your admin password or OAuth token)
5. Save.

Once connected, the native SNOW tools (`GetServiceNowIncident`, `PostServiceNowDiscussionEntry`, `AcknowledgeServiceNowIncident`, `ResolveServiceNowIncident`) become available to the subagent automatically.

### Filter behaviour

The `snow-laptop-replacement` filter triggers on:
- `categoryFilter: hardware`
- `shortDescriptionContains: laptop`
- Priorities 3, 4, 5
- Events: `IncidentCreated`, `IncidentUpdated`

To test: create a SNOW incident with category=Hardware, priority=4, short description "Laptop replacement request", and a description containing employee details + serial number.

## Azure Monitor alerts

This recipe **does not** subscribe to Azure Monitor — it is purely SNOW-driven. If you want AzMon-driven incidents in this same agent, use the `azmon-aca-servicenow-zavaitsupport-ops` recipe instead.

## Cost

Single-subagent, low-volume helpdesk automation. Monthly Agent Unit budget capped at 5000 in `agent.json` — adjust if you process many tickets.


