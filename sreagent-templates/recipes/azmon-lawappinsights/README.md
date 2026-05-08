# azmon-lawappinsights

Azure Monitor agent with Log Analytics and App Insights for investigating alerts and triaging application errors.

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
| azd | `azd up` (see [main README](../../README.md) for setup) |

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| agentName | ✅ | `azmon-contoso` | You choose (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-azmon-contoso` | You choose or use existing RG |
| location | ✅ | `swedencentral` | Azure region ([supported regions](../../README.md)) |
| targetRGs | ✅ | `rg-contoso-prod,rg-contoso-web` | Comma-separated RG names to monitor |
| lawId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>` | Portal → LAW → Properties → Resource ID |
| appInsightsId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/components/<name>` | Portal → App Insights → Properties → Resource ID |
| appInsightsAppId | | `b2c3d4e5-...` | Portal → App Insights → API Access → Application ID |
| githubRepo | | `contoso/trading-app` | GitHub org/repo for code context (optional) |

### Advanced Options

| Param | Example | Description |
|---|---|---|
| existingUamiId | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>` | Use an existing User-Assigned Managed Identity instead of creating a new one. Portal → Managed Identities → Properties → Resource ID |
| existingAgentAppInsightsId | `/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/components/<name>` | Use an existing Application Insights for agent telemetry instead of creating a new one. Portal → App Insights → Properties → Resource ID |
| modelProvider | `Anthropic`, `MicrosoftFoundry` | `Anthropic` = Claude, `MicrosoftFoundry` = Azure OpenAI. Default: `Anthropic` |

## What You Get

- **Platform**: Azure Monitor (Sev0+Sev1, Autonomous)
- **Connectors**: Application Insights, Log Analytics Workspace (toggle-based)
- **Skills**: investigate-azure-alerts, triage-app-errors
- **Subagents**: alert-investigator, remediation-advisor
- **Response Plan**: azmon-sev01 — triggers on Sev0 and Sev1 alerts autonomously
- **Scheduled Task**: daily-health-check (runs daily at 08:00 UTC)
- **Hooks**: deny-prod-deletes, require-approval-for-restarts
- **Repo**: contoso-trading (placeholder)

## Clone

```bash
# Get your subscription ID
SUB=$(az account show --query id -o tsv)

./bin/export-agent.sh -s $SUB -g rg-azmon-contoso -n azmon-contoso \
  -o azmon-clone/ \
  --set agentName=azmon-staging \
  --set resourceGroup=rg-azmon-staging

# Before deploying — verify connector permissions for the new environment:
#   1. Check connectors.json — LAW workspace ID, App Insights resource ID
#      must be accessible from the new agent's UAMI
#   2. Check automations/ — alert triggers, scheduled tasks
#   3. Check connectors.secrets.env — any environment-specific secrets
#   4. After deploy, grant UAMI Log Analytics Reader and App Insights Reader roles

# Review config — check connectors.json, connectors.secrets.env, and automations/
./bin/deploy.sh azmon-clone/
```
