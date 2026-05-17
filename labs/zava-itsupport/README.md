# Zava — IT Support SRE Agent Lab

A standalone lab that simulates an internal IT helpdesk: employees submit
laptop replacement requests, an Azure SRE Agent (the `it-support-handler`)
is triggered by ServiceNow incidents, looks up device warranty via a custom
Python tool, and drafts the replacement response — fully autonomous.

## Stack

- **App**: Node.js 20 — `laptop-request-site/` IT portal (Container App, port 8080); Python 3.11 + FastAPI — `warranty-tool/` warranty-lookup API (Container App, port 8000)
- **Compute**: Azure Container Apps (single ACA Environment hosts both apps)
- **Data**: None (warranty data is mocked in `warranty-tool/`; ServiceNow PDI is the system of record for tickets)
- **Observability**: Application Insights + Log Analytics Workspace
- **SRE Agent**: `sre-agent-zava-itsupport-<token>` — autonomous, Container Apps Contributor scope. Subagent: `it-support-handler` (with native ServiceNow tools + `CheckWarranty` + `LookupServiceNowIncident` + `SendOutlookEmail`). HTTP trigger `zava-itsupport-incident-trigger` for ServiceNow MCP. No skills, no hooks, no scheduled tasks — single-purpose automation.
- **Simulator**: Bash demo script (`scripts/laptop-request-demo.sh`) that files a sample request against the deployed portal
- **CI/CD**: `azd up` (Bicep → ACR build/push for both images → `srectl apply` → HTTP trigger registration)

## What it's about

This lab focuses purely on the IT-support automation slice that originally
shipped inside `zava-cafe`. It deploys two small Container Apps (a Node.js
laptop-request portal + a Python warranty-lookup API), wires up an SRE Agent
with the `it-support-handler` subagent and its `CheckWarranty` /
`LookupServiceNowIncident` tools, and registers an HTTP trigger so the
ServiceNow MCP connector (or any external system) can invoke the workflow.

The end-to-end story: a ServiceNow ticket comes in describing a hardware
issue → the trigger wakes the agent → the agent fetches the ticket details
→ checks the device serial against the warranty API → if eligible, files
the replacement request via the portal and resolves the SNOW ticket. The
lab is for PMs/SREs/customers who want to see how the SRE Agent automates
a ServiceNow-driven helpdesk workflow with custom Python tools — distinct
from the AzMon-driven infrastructure-ops scenarios in the other labs.

## Quick start

```bash
azd auth login
az login
azd up
bash scripts/laptop-request-demo.sh
```

## Demo flow

1. `azd up` — provisions the resource group, ACR, both Container Apps,
   App Insights, the SRE Agent instance, and managed identities.
2. `scripts/post-provision.sh` runs automatically — it builds + pushes the
   2 container images, updates the Container Apps to the new tags, registers
   the agent + tools via `srectl`, and creates the HTTP trigger
   `zava-itsupport-incident-trigger`.
3. Connect ServiceNow as the Incident Platform in the SRE Agent UI
   (`sre.azure.com` → your agent → Builder → Incidents → Connect platform).
4. Run `bash scripts/laptop-request-demo.sh` to file a sample laptop
   replacement request against the deployed IT portal — the agent picks
   it up via the trigger and runs the warranty + replacement workflow.
5. Watch the thread at `https://sre.azure.com` to see the agent step
   through `LookupServiceNowIncident` → `CheckWarranty` → portal submission
   → ticket resolution.

## Skipping the srectl block

Set `LABS_SKIP_SRECTL=1` before `azd up` (or before re-running
`bash scripts/post-provision.sh`) to skip agent registration entirely —
useful if `srectl` is not yet available in your environment (it is currently
in private preview).
