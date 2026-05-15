# dynatrace-mcp

Dynatrace MCP connector for investigating application errors with skills and subagents.

## Prerequisites

- Azure subscription with target resource groups
- Dynatrace environment with an API token (scopes: `entities.read`, `events.read`, `metrics.read`)
- GitHub repo with app source code (optional — for code context during investigations)
- All [CLI tools](../../README.md#prerequisites) installed (`./bin/install-prerequisites.sh --check`)

## Quick Start

### Step 1 — Generate agent config

**Bash:**
```bash
./bin/new-agent.sh --recipe dynatrace-mcp --non-interactive \
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
./bin/ps/New-Agent.ps1 -Recipe dynatrace-mcp -NonInteractive `
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
| azd | `azd up` (see [main README](../../README.md#azure-developer-cli-azd) for setup) |

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| agentName | ✅ | `dt-contoso` | You choose (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-dt-contoso` | You choose or use existing RG |
| location | ✅ | `swedencentral` | Azure region — see [supported regions](../../README.md) |
| dtTenant | ✅ | `abc12345` | Dynatrace → Settings → Environment ID (the subdomain in `abc12345.apps.dynatrace.com`) |
| dtToken | ✅ | `dt0c01.ABCDEFGH.XXXX...` | Dynatrace → Access tokens → Create (scopes: `entities.read`, `events.read`, `metrics.read`) |
| targetRGs | ✅ | `rg-contoso-prod,rg-contoso-web` | Comma-separated RG names to monitor |
| lawId | | `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>` | Portal → LAW → Properties → Resource ID. If blank, the LAW connector is disabled. |
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
| **Connectors** | Dynatrace (MCP, bearer token), Log Analytics (optional, if lawId provided) |
| **Skills** | investigate-app-errors |
| **Subagents** | dynatrace-investigator |
| **Hooks** | deny-prod-deletes |
| **Common Prompts** | safety-rules |

> **Note:** This recipe does not include a response plan or scheduled tasks. To add automated incident response, create files in `automations/incident-filters/` and `automations/incident-platforms/` — see the [azmon recipe](../azmon-lawappinsights/) for examples.

## After Deploy

1. Open [SRE Agent portal](https://sre.azure.com) → Connections → verify Dynatrace shows "Connected"
2. Grant the agent's UAMI appropriate RBAC on target resource groups (Reader at minimum)
3. To connect a GitHub repo, uncomment the GitHub section in `roles.yaml` and redeploy, or configure in the portal

## Clone an Existing Agent

```bash
SUB=$(az account show --query id -o tsv)

./bin/export-agent.sh -s $SUB -g rg-dt-contoso -n dt-contoso \
  -o dt-clone/ \
  --set agentName=dt-staging \
  --set resourceGroup=rg-dt-staging

# If cloning to a different Dynatrace environment, update DYNATRACE_BEARER_TOKEN
# in connectors.secrets.env with a token from the new tenant.

# Review the exported config:
#   - connectors.json — verify Dynatrace tenant URL is correct
#   - connectors.secrets.env — update token if changing tenants
#   - roles.yaml — Dynatrace token instructions

./bin/deploy.sh dt-clone/
```
