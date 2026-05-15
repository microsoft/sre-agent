# bare

Minimal SRE Agent — deploys the agent infrastructure and RBAC with no connectors, skills, or automations. Use this as a starting point when none of the other recipes match your setup.

## Prerequisites

- Azure subscription with at least one resource group to monitor
- All [CLI tools](../../README.md#prerequisites) installed (`./bin/install-prerequisites.sh --check`)

## Quick Start

### Step 1 — Generate agent config

**Bash:**
```bash
./bin/new-agent.sh --recipe bare --non-interactive \
  --set agentName=my-agent \
  --set resourceGroup=rg-my-agent \
  --set location=swedencentral \
  --set targetRGs=rg-my-workload \
  -o my-agent/
```

**PowerShell:**
```powershell
./bin/ps/New-Agent.ps1 -Recipe bare -NonInteractive `
  -Set @{agentName='my-agent'; resourceGroup='rg-my-agent'; location='swedencentral';
    targetRGs='rg-my-workload'} `
  -Output my-agent/
```

### Step 2 — Deploy (pick any backend)

| Backend | Command |
|---|---|
| Bicep | `./bin/deploy.sh my-agent/` |
| Terraform | `./bin/deploy-tf.sh my-agent/` |
| PowerShell | `./bin/ps/Deploy-Agent.ps1 -InputPath my-agent/` |
| azd | `azd up` (see [main README](../../README.md#azure-developer-cli-azd) for setup) |

## Parameters

| Param | Required | Example | How to get it |
|---|---|---|---|
| agentName | ✅ | `my-agent` | You choose (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-my-agent` | You choose or use existing RG |
| location | ✅ | `swedencentral` | Azure region — see [supported regions](../../README.md) |
| targetRGs | ✅ | `rg-my-workload` | Comma-separated RG names to monitor |

### Advanced Options

| Param | Default | Description |
|---|---|---|
| existingUamiId | (create new) | ARM resource ID of an existing User-Assigned Managed Identity. Leave blank to create a new one. |
| existingAgentAppInsightsId | (create new) | ARM resource ID of an existing Application Insights for **agent telemetry**. Leave blank to create a new one. |
| modelProvider | `Anthropic` | AI model provider. Options: `Anthropic`, `Azure OpenAI`. |

## What You Get

| Category | Items |
|---|---|
| **Infrastructure** | Resource Group, UAMI, LAW, App Insights, RBAC |
| **Agent** | SRE Agent with Review mode (no autonomous actions) |
| **Common Prompts** | safety-rules |
| **Connectors** | None (add your own) |
| **Skills** | None (add your own) |
| **Automations** | None (add your own) |

## Adding Connectors and Skills

After deploying the bare agent, add capabilities by dropping files into the config directory:

```
my-agent/
  config/
    skills/           ← add .yaml + .md files for investigation skills
    subagents/        ← add .yaml + .instructions.md for subagents
    hooks/            ← add .yaml for safety hooks
    common-prompts/   ← add .yaml for shared prompts
    repos/            ← add .yaml to connect GitHub/ADO repos
  connectors.json     ← edit to enable LAW, App Insights, or add MCP connectors
  automations/
    incident-filters/ ← add .yaml for severity-based auto-response
    scheduled-tasks/  ← add .yaml for recurring tasks
```

Then redeploy:
```bash
./bin/deploy.sh my-agent/
```

See the other recipes for examples of each file type:
- [azmon-lawappinsights](../azmon-lawappinsights/) — skills, subagents, hooks, scheduled tasks, incident response
- [pagerduty-law-vmcosmos](../pagerduty-law-vmcosmos/) — skills, hooks, knowledge files
- [dynatrace-mcp](../dynatrace-mcp/) — MCP connector, subagent

## After Deploy

1. Open [SRE Agent portal](https://sre.azure.com) → verify the agent shows "Running"
2. Add connectors, skills, and automations as needed (see above)
3. When ready for autonomous response, change `accessLevel` and `actionMode` in `agent.json`
