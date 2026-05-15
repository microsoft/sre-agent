# pagerduty-law-vmcosmos

Monitor PagerDuty P1/P2 incidents with Log Analytics and App Insights, targeting VM and Cosmos DB workloads.

## Prerequisites

- Azure subscription with resource groups containing your VMs and/or Cosmos DB accounts
- PagerDuty account with an API key ([create one here](https://support.pagerduty.com/docs/api-access-keys))
- Application Insights and/or Log Analytics workspace (optional — these connect to *your* existing monitoring data)
- All [CLI tools](../../README.md#prerequisites) installed (`./bin/install-prerequisites.sh --check`)

## Quick Start

### Step 1 — Generate agent config

**Bash:**
```bash
./bin/new-agent.sh --recipe pagerduty-law-vmcosmos --non-interactive \
  --set agentName=pd-contoso-prod \
  --set resourceGroup=rg-pd-contoso \
  --set location=swedencentral \
  --set lawId=/subscriptions/.../workspaces/contoso-law \
  --set pagerdutyApiKey=u+abCdEfGhIjKlMnOpQrSt \
  --set targetRGs=rg-contoso-prod,rg-contoso-cosmos \
  -o pd-contoso-prod/
```

**PowerShell:**
```powershell
./bin/ps/New-Agent.ps1 -Recipe pagerduty-law-vmcosmos -NonInteractive `
  -Set @{agentName='pd-contoso-prod'; resourceGroup='rg-pd-contoso'; location='swedencentral';
    lawId='/subscriptions/.../workspaces/contoso-law';
    pagerdutyApiKey='u+abCdEfGhIjKlMnOpQrSt'; targetRGs='rg-contoso-prod,rg-contoso-cosmos'} `
  -Output pd-contoso-prod/
```

### Step 2 — Deploy (pick any backend)

| Backend | Command |
|---|---|
| Bicep | `./bin/deploy.sh pd-contoso-prod/` |
| Terraform | `./bin/deploy-tf.sh pd-contoso-prod/` |
| PowerShell | `./bin/ps/Deploy-Agent.ps1 -InputPath pd-contoso-prod/` |
| azd | `azd up` (see [main README](../../README.md#azure-developer-cli-azd) for setup) |

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| agentName | ✅ | `pd-contoso-prod` | You choose (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-pd-contoso` | You choose or use existing RG |
| location | ✅ | `swedencentral` | Azure region — see [supported regions](../../README.md) |
| pagerdutyApiKey | ✅ | `u+abCdEfGhIjKlMnOpQrSt` | PagerDuty → Integrations → API Access Keys → Create |
| targetRGs | ✅ | `rg-contoso-prod,rg-contoso-cosmos` | Comma-separated RG names with your VMs/Cosmos DBs |
| lawId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>` | Portal → LAW → Properties → Resource ID. If blank, the LAW connector is disabled. |
| appInsightsId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/components/<name>` | Portal → App Insights → Properties → **Resource ID**. If blank, the App Insights connector is disabled. |
| appInsightsAppId | | `b2c3d4e5-...` | Portal → App Insights → API Access → **Application ID** (GUID). This is different from appInsightsId — it's the GUID from the API Access page, not the ARM resource ID. |

### Advanced Options

| Param | Default | Description |
|---|---|---|
| existingUamiId | (create new) | ARM resource ID of an existing User-Assigned Managed Identity. Leave blank to create a new one. |
| existingAgentAppInsightsId | (create new) | ARM resource ID of an existing Application Insights for **agent telemetry** (not your app's AI). Leave blank to create a new one. |
| modelProvider | `Anthropic` | AI model provider. Options: `Anthropic`, `Azure OpenAI`. |

## What You Get

| Category | Items |
|---|---|
| **Platform** | PagerDuty via connectionKey (P1+P2, Autonomous) |
| **Connectors** | Log Analytics Workspace, Application Insights (enabled based on params above) |
| **Skills** | investigate-vm-issues, investigate-cosmosdb, investigate-http-errors |
| **Response Plan** | pd-p1p2 — triggers on P1 and P2 incidents autonomously |
| **Hooks** | deny-prod-deletes, vm-remediation-approval |
| **Knowledge** | http-500-errors.md, incident-report-template.md, vm-cosmosdb-architecture.md |
| **Common Prompts** | safety-rules |

## After Deploy

1. Open [SRE Agent portal](https://sre.azure.com) → Connections → verify PagerDuty shows "Connected"
2. Select which PagerDuty services to monitor in the agent's platform settings
3. If you provided `lawId` / `appInsightsId`, verify those connectors show "Connected"

## Clone an Existing Agent

```bash
SUB=$(az account show --query id -o tsv)

./bin/export-agent.sh -s $SUB -g rg-pd-contoso -n pd-contoso-prod \
  -o pd-clone/ \
  --set agentName=pd-contoso-staging \
  --set resourceGroup=rg-pd-staging \
  --set "pagerdutyApiKey=u+newKeyForClone"

# pagerdutyApiKey is redacted on export — you must provide a valid key via --set
# or update connectors.secrets.env before deploying.

# Review the exported config:
#   - connectors.json — verify LAW/AI resource IDs are accessible from new location
#   - connectors.secrets.env — update PagerDuty key and any other secrets
#   - automations/ — incident filters, platform config

./bin/deploy.sh pd-clone/
```
