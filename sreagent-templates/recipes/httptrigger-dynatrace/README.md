# httptrigger-dynatrace

Dynatrace MCP connector for investigating application errors with skills and subagents.

## Quick Start

### Step 1 — Generate agent config

**Bash:**
```bash
./bin/new-agent.sh --recipe httptrigger-dynatrace --non-interactive \
  --set agentName=dt-contoso \
  --set resourceGroup=rg-dt-contoso \
  --set location=swedencentral \
  --set dtTenant=abc12345 \
  --set dtToken=dt0c01.ABCDEFGH.XXXXXXXX... \
  --set targetRGs=rg-contoso-prod,rg-contoso-web \
  -o dt-contoso/
```

**PowerShell:**
```powershell
./bin/ps/New-Agent.ps1 -Recipe httptrigger-dynatrace -NonInteractive `
  -Set @{agentName='dt-contoso'; resourceGroup='rg-dt-contoso'; location='swedencentral';
    dtTenant='abc12345'; dtToken='dt0c01.ABCDEFGH.XXXXXXXX...';
    targetRGs='rg-contoso-prod,rg-contoso-web'} `
  -Output dt-contoso/
```

### Step 2 — Deploy (pick any backend)

| Backend | Command |
|---|---|
| Bicep | `./bin/deploy.sh dt-contoso/` |
| Terraform | `./bin/deploy-tf.sh dt-contoso/` |
| PowerShell | `./bin/ps/Deploy-Agent.ps1 -InputPath dt-contoso/` |
| azd | `azd up` (see [main README](../../README.md) for setup) |

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| agentName | ✅ | `dt-contoso` | You choose (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-dt-contoso` | You choose or use existing RG |
| location | ✅ | `swedencentral` | Azure region ([supported regions](../../README.md)) |
| dtTenant | ✅ | `abc12345` | Dynatrace → Settings → Environment ID |
| dtToken | ✅ | `dt0c01.ABCDEFGH.XXXX...` | Dynatrace → Access tokens → Create (scopes: Read problems, Read entities) |
| targetRGs | ✅ | `rg-contoso-prod,rg-contoso-web` | Comma-separated RG names to monitor |
| lawId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>` | Portal → LAW → Properties → Resource ID (optional) |
| githubRepo | | `contoso/trading-app` | GitHub org/repo for code context (optional) |

### Advanced Options

| Param | Example | Description |
|---|---|---|
| existingUamiId | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>` | Use an existing UAMI instead of creating a new one. Portal → Managed Identities → Properties → Resource ID |
| existingAgentAppInsightsId | `/subscriptions/<sub>/resourceGroups/<rg>/providers/microsoft.insights/components/<name>` | Use an existing Application Insights for agent telemetry instead of creating a new one. Portal → App Insights → Properties → Resource ID |
| modelProvider | `Anthropic`, `GitHubCopilot`, `MicrosoftFoundry` | Default LLM provider. Default: `Anthropic` |

## What You Get

- **Connectors**: Dynatrace (MCP, bearer token), Log Analytics (optional)
- **Skills**: investigate-app-errors
- **Subagents**: dynatrace-investigator
- **Hooks**: deny-prod-deletes
- **Repo**: github-repo (placeholder)

## After Deploy

1. In Dynatrace → Settings → Workflows → configure alerting to trigger investigations
2. Grant the agent UAMI appropriate RBAC on target resource groups

## Clone

```bash
# Get your subscription ID
SUB=$(az account show --query id -o tsv)

./bin/export-agent.sh -s $SUB -g rg-dt-contoso -n dt-contoso \
  -o dt-clone/ \
  --set agentName=dt-staging \
  --set resourceGroup=rg-dt-staging

# If cloning to a different Dynatrace environment, update DYNATRACE_BEARER_TOKEN
# in connectors.secrets.env with a token from the new tenant.

# Review config — check connectors.json, connectors.secrets.env, and automations/
./bin/deploy.sh dt-clone/
```

> Token exports from data-plane (not redacted), but verify `connectors.secrets.env` after export.
