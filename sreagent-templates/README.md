# Azure SRE Agent Recipes

Production-ready recipes to deploy SRE Agents as code. Pick a recipe, run two commands, deploy.

## Prerequisites

[Azure Cloud Shell](https://shell.azure.com) has everything pre-installed — no setup needed.

For local use:

| Tool | Install |
|---|---|
| Azure CLI (`az`) | `brew install azure-cli` or [install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |
| `jq` | `brew install jq` / `apt install jq` / `choco install jq` |
| Python 3 + PyYAML | `brew install python3 && pip3 install pyyaml` |
| `curl` | Pre-installed on macOS/Linux |
| `bash` 3.2+ | Pre-installed on macOS/Linux. Windows: use WSL or Git Bash |

## Quick Start

```bash
git clone https://github.com/microsoft/sre-agent.git
cd sre-agent/sreagent-templates

# Create agent config from a recipe
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=my-agent \
  --set resourceGroup=rg-my-agent \
  --set location=swedencentral \       # or eastus2, uksouth, australiaeast
  --set targetRGs=rg-my-workload \
  -o my-agent/

# Deploy (~3 min)
./bin/deploy.sh my-agent/
```

> **Cloud Shell**: Core deployment works with Cloud Shell's built-in auth. Some data-plane items (hooks, repos) require `az login --scope "https://azuresre.dev/.default"` first, or can be configured later in the [portal](https://sre.azure.com).

## Recipes

## Recipes

| Recipe | Platform | One-line |
|---|---|---|
| [azmon-lawappinsights](recipes/azmon-lawappinsights/) | Azure Monitor | Alert response with AppInsights + Log Analytics, skills, subagents, scheduled tasks |
| [pagerduty-law-vmcosmos](recipes/pagerduty-law-vmcosmos/) | PagerDuty | VM + CosmosDB + HTTP error investigation with knowledge files and skills |
| [httptrigger-dynatrace](recipes/httptrigger-dynatrace/) | HTTP Trigger | Dynatrace MCP connector + webhook bridge, auto-creates GitHub issues |

Each recipe README has the full parameter list, example values, and post-deploy steps.

## CLI

| Command | Purpose |
|---|---|
| `new-agent.sh --recipe <name> --set key=val -o dir/` | Create agent config from recipe |
| `deploy.sh dir/` | Deploy (Bicep + data-plane, ~3 min) |
| `deploy.sh dir/ --dry-run` | Assemble only, no ARM call |
| `deploy.sh dir/ --what-if` | ARM validation without deploying |
| `deploy.sh dir/ --force` | Redeploy even if no changes detected |
| `export-agent.sh --set agentName=clone -o dir/` | Export/clone a live agent |
| `diff-agent.sh $SUB $RG $AGENT dir/` | Compare config vs live agent |
| `verify-agent.sh $SUB $RG $AGENT --expected dir/` | 22-point verification |

## Deploy Backends

The same config directory works with any backend:

| Backend | Command | Best for |
|---|---|---|
| **Bicep** (default) | `deploy.sh dir/` | Azure-native, Cloud Shell, CI/CD |
| **Terraform** | `deploy-tf.sh dir/` | Multi-cloud teams, TF state management |
| **azd** | `azd up` | Azure Developer CLI, `azd` template ecosystem |
| **PowerShell** | `Deploy-Agent.ps1 -InputPath dir/` | Windows, Cloud Shell (PS) |

All backends run the same steps: assemble config → deploy infra → apply extras (data-plane).

## Clone an Agent

```bash
# Export source agent config
./bin/export-agent.sh -s $SUB -g rg-source -n my-agent \
  -o my-clone/ \
  --set agentName=my-clone \
  --set resourceGroup=rg-clone \
  --set location=swedencentral

# Deploy with any backend
./bin/deploy.sh my-clone/           # Bicep
./bin/deploy-tf.sh my-clone/        # Terraform
```

## Terraform

Uses the `azapi` provider for `Microsoft.App/agents`. Same config directory, same results as Bicep.

```bash
# Create + deploy (identical to Bicep flow)
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=my-agent \
  --set resourceGroup=rg-my-agent \
  --set location=swedencentral \
  --set targetRGs=rg-my-workload \
  -o my-agent/

./bin/deploy-tf.sh my-agent/

# Update (re-run — TF diffs and applies only changes)
./bin/deploy-tf.sh my-agent/

# Clone
./bin/export-agent.sh -s $SUB -g rg-my-agent -n my-agent \
  -o my-clone/ --set agentName=my-clone --set resourceGroup=rg-clone
./bin/deploy-tf.sh my-clone/

# Destroy
./bin/deploy-tf.sh my-agent/ --destroy
```

Each agent gets its own Terraform workspace — deploy multiple agents from the same repo without state conflicts.

### Prerequisites (Terraform only)

| Tool | Install |
|---|---|
| Terraform 1.5+ | [install guide](https://developer.hashicorp.com/terraform/install) |
| azapi provider | Auto-installed on `terraform init` |
| azurerm provider | Auto-installed on `terraform init` |

### What It Creates

| Resource | Provider |
|---|---|
| Resource Group, UAMI, LAW, App Insights | azurerm |
| SRE Agent | azapi |
| Connectors, Skills, Subagents, Tools, Common Prompts | azapi |
| RBAC (Reader, Log Analytics Reader, Monitoring Reader, SRE Agent Admin) | azurerm |

> **Region note**: Use `swedencentral` for fastest provisioning.

## Azure Developer CLI (azd)

Wraps the Bicep flow in `azd up`. Set environment variables, run one command.

```bash
# Initialize
azd init -t sreagent-recipes   # or clone + cd into repo
azd env new my-agent

# Set recipe + parameters
azd env set RECIPE azmon-lawappinsights
azd env set AZURE_AGENT_NAME my-agent
azd env set AZURE_RESOURCE_GROUP rg-my-agent
azd env set AZURE_LOCATION swedencentral
azd env set AZURE_TARGET_RGS rg-my-workload
azd env set AZURE_LAW_ID "/subscriptions/.../workspaces/my-law"
azd env set AZURE_AI_ID "/subscriptions/.../components/my-ai"
azd env set AZURE_AI_APPID "00000000-0000-0000-0000-000000000000"

# Deploy (create or update)
azd up

# Clone: export, create new env, azd up
./bin/export-agent.sh -s $SUB -g rg-my-agent -n my-agent \
  -o agents/my-clone/ --set agentName=my-clone --set resourceGroup=rg-clone
azd env new my-clone
azd env set AZURE_AGENT_NAME my-clone
azd env set AZURE_RESOURCE_GROUP rg-clone
azd env set AZURE_LOCATION swedencentral
azd up

# Destroy
azd down
```

Recipe-specific env vars:

| Recipe | Extra env vars |
|---|---|
| pagerduty | `PAGERDUTY_API_KEY` |
| dynatrace | `DT_TENANT`, `DT_TOKEN`, `GITHUB_REPO` |

## PowerShell

Full PowerShell 7+ port in [`bin/ps/`](bin/ps/). Same config directory, same results.

```powershell
./bin/ps/New-Agent.ps1 -Recipe azmon-lawappinsights -NonInteractive `
  -Set @{agentName='my-agent'; resourceGroup='rg-my-agent'; location='swedencentral'; targetRGs='rg-my-workload'} `
  -Output my-agent/

./bin/ps/Deploy-Agent.ps1 -InputPath my-agent/
```

| Script | Purpose |
|---|---|
| `New-Agent.ps1` | Create agent config from recipe |
| `Deploy-Agent.ps1` | Deploy (Bicep + apply-extras) |
| `Export-Agent.ps1` | Export/clone a live agent |
| `Verify-Agent.ps1` | 22-point verification |
| `Diff-Agent.ps1` | Compare config vs live agent |

## CI/CD

See [examples/ci-cd/](examples/ci-cd/) for GitHub Actions and step-by-step setup.

## Contributing

A recipe is defined by 5 dimensions — think through each for your use case:

1. **Incident Platform** — AzMonitor, PagerDuty, ServiceNow, or HTTP webhook
2. **Connectors** — Log Analytics, App Insights, Kusto, MCP (Dynatrace/Datadog/custom)
3. **Skills** — investigation playbooks for your workload (VM, CosmosDB, HTTP errors, etc.)
4. **Knowledge** — runbooks, architecture docs, incident templates
5. **Response Plan** — severity filter, autonomous vs review, customInstructions prompt

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full recipe design guide, naming conventions, and PR guidelines.
