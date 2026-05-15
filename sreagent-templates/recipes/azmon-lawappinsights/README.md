# azmon-lawappinsights

Azure Monitor agent with Log Analytics and App Insights for investigating alerts and triaging application errors.

## Prerequisites

- Azure subscription with at least one resource group to monitor
- Application Insights and/or Log Analytics workspace (optional — the agent creates its own telemetry resources; these are for connecting to *your* existing monitoring data)
- All [CLI tools](../../README.md#prerequisites) installed (`./bin/install-prerequisites.sh --check`)

## Quick Start

### Step 1 — Generate agent config

**Bash:**
```bash
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=azmon-contoso \
  --set resourceGroup=rg-azmon-contoso \
  --set location=swedencentral \
  --set lawId=/subscriptions/.../workspaces/contoso-law \
  --set appInsightsId=/subscriptions/.../components/contoso-ai \
  --set appInsightsAppId=b2c3d4e5-... \
  --set targetRGs=rg-contoso-prod,rg-contoso-web \
  -o azmon-contoso/
```

**PowerShell:**
```powershell
./bin/ps/New-Agent.ps1 -Recipe azmon-lawappinsights -NonInteractive `
  -Set @{agentName='azmon-contoso'; resourceGroup='rg-azmon-contoso'; location='swedencentral';
    lawId='/subscriptions/.../workspaces/contoso-law';
    appInsightsId='/subscriptions/.../components/contoso-ai';
    appInsightsAppId='b2c3d4e5-...'; targetRGs='rg-contoso-prod,rg-contoso-web'} `
  -Output azmon-contoso/
```

### Step 2 — Deploy (pick any backend)

| Backend | Command |
|---|---|
| Bicep | `./bin/deploy.sh azmon-contoso/` |
| Terraform | `./bin/deploy-tf.sh azmon-contoso/` |
| PowerShell | `./bin/ps/Deploy-Agent.ps1 -InputPath azmon-contoso/` |
| azd | `azd up` (see [main README](../../README.md#azure-developer-cli-azd) for setup) |

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| agentName | ✅ | `azmon-contoso` | You choose (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-azmon-contoso` | You choose or use existing RG |
| location | ✅ | `swedencentral` | Azure region — see [supported regions](../../README.md) |
| targetRGs | ✅ | `rg-contoso-prod,rg-contoso-web` | Comma-separated RG names to monitor |
| lawId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>` | Portal → LAW → Properties → Resource ID. If blank, the LAW connector is disabled. |
| appInsightsId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/components/<name>` | Portal → App Insights → Properties → **Resource ID**. If blank, the App Insights connector is disabled. |
| appInsightsAppId | | `b2c3d4e5-...` | Portal → App Insights → API Access → **Application ID** (GUID). This is different from appInsightsId — it's the GUID from the API Access page, not the ARM resource ID. |
| githubRepo | | `contoso/trading-app` | GitHub org/repo for code context (optional) |

### Advanced Options

| Param | Default | Description |
|---|---|---|
| existingUamiId | (create new) | ARM resource ID of an existing User-Assigned Managed Identity. Leave blank to create a new one. |
| existingAgentAppInsightsId | (create new) | ARM resource ID of an existing Application Insights for **agent telemetry** (not your app's AI). Leave blank to create a new one. |
| modelProvider | `Anthropic` | AI model provider. Options: `Anthropic`, `Azure OpenAI`. |

## What You Get

| Category | Items |
|---|---|
| **Platform** | Azure Monitor (Sev0+Sev1, Autonomous) |
| **Connectors** | Application Insights, Log Analytics Workspace (enabled based on params above) |
| **Skills** | investigate-azure-alerts, triage-app-errors |
| **Subagents** | alert-investigator, remediation-advisor |
| **Response Plan** | azmon-sev01 — triggers on Sev0 and Sev1 alerts autonomously |
| **Scheduled Task** | daily-health-check (runs daily at 08:00 UTC) |
| **Hooks** | deny-prod-deletes, require-approval-for-restarts |
| **Common Prompts** | investigation-guidelines, safety-rules |

## After Deploy

1. Open [SRE Agent portal](https://sre.azure.com) → verify the agent shows "Running"
2. If you provided `lawId` / `appInsightsId`, verify those connectors show "Connected"
3. To connect a GitHub repo, uncomment the GitHub section in `roles.yaml` and redeploy, or configure in the portal

## Clone an Existing Agent

```bash
SUB=$(az account show --query id -o tsv)

./bin/export-agent.sh -s $SUB -g rg-azmon-contoso -n azmon-contoso \
  -o azmon-clone/ \
  --set agentName=azmon-staging \
  --set resourceGroup=rg-azmon-staging

# Review the exported config:
#   - connectors.json — verify LAW/AI resource IDs are accessible from new location
#   - connectors.secrets.env — any environment-specific secrets
#   - automations/ — alert triggers, scheduled tasks

./bin/deploy.sh azmon-clone/
```
