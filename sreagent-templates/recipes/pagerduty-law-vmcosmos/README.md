# pagerduty-law-vmcosmos

Monitor PagerDuty P1/P2 incidents with Log Analytics and App Insights, targeting VM and Cosmos DB workloads.

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
| azd | `azd up` (see [main README](../../README.md) for setup) |

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| agentName | ✅ | `pd-contoso-prod` | You choose (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-pd-contoso` | You choose or use existing RG |
| location | ✅ | `swedencentral` | Azure region ([supported regions](../../README.md)) |
| pagerdutyApiKey | ✅ | `u+abCdEfGhIjKlMnOpQrSt` | PagerDuty → Integrations → API Access Keys → Create |
| targetRGs | ✅ | `rg-contoso-prod,rg-contoso-cosmos` | Comma-separated RG names with your VMs/Cosmos DBs |
| lawId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>` | Portal → LAW → Properties → Resource ID |
| appInsightsId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/components/<name>` | Portal → App Insights → Properties → Resource ID |
| appInsightsAppId | | `b2c3d4e5-...` | Portal → App Insights → API Access → Application ID |

### Advanced Options

| Param | Example | Description |
|---|---|---|
| existingUamiId | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>` | Use an existing UAMI instead of creating a new one. Portal → Managed Identities → Properties → Resource ID |
| existingAgentAppInsightsId | `/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/components/<name>` | Use an existing Application Insights for agent telemetry instead of creating a new one. Portal → App Insights → Properties → Resource ID |
| modelProvider | `Anthropic`, `GitHubCopilot`, `MicrosoftFoundry` | Default LLM provider. Default: `Anthropic` |

## What You Get

- **Platform**: PagerDuty via connectionKey (P1+P2, Autonomous)
- **Connectors**: Log Analytics Workspace, Application Insights (toggle-based)
- **Skills**: investigate-vm-issues, investigate-cosmosdb, investigate-http-errors
- **Response Plan**: pd-p1p2 — triggers on P1 and P2 incidents autonomously
- **Hooks**: deny-prod-deletes, vm-remediation-approval
- **Knowledge**: http-500-errors.md, incident-report-template.md, vm-cosmosdb-architecture.md

## After Deploy

1. Open Portal → SRE Agent → Connections → verify PagerDuty shows "Connected"
2. Select which PagerDuty services to monitor in the agent's platform settings

## Clone

```bash
# Get your subscription ID
SUB=$(az account show --query id -o tsv)

./bin/export-agent.sh -s $SUB -g rg-pd-contoso -n pd-contoso-prod \
  -o pd-clone/ \
  --set agentName=pd-contoso-staging \
  --set resourceGroup=rg-pd-staging \
  --set "pagerdutyApiKey=u+newKeyForClone"

# pagerdutyApiKey is redacted on export — you must provide a valid key via --set
# or update connectors.secrets.env before deploying.

# Review config — check connectors.json, connectors.secrets.env, and automations/
./bin/deploy.sh pd-clone/
```
