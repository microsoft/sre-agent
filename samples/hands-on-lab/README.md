# Azure SRE Agent Hands-On Lab

Deploy an Azure SRE Agent connected to a sample application with a single `azd up` command. Watch it diagnose and remediate issues autonomously.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | 2.60+ | `brew install azure-cli` |
| [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) | 1.9+ | `brew install azd` |
| [Git](https://git-scm.com/) | 2.x | `brew install git` |

**Azure Requirements:**
- Active Azure subscription with **Owner** or **User Access Administrator** role
- `Microsoft.App` resource provider registered on the subscription

**Optional (for GitHub integration):**
- GitHub account with a [Personal Access Token](https://github.com/settings/tokens) (repo scope)

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/dm-chelupati/sre-agent-lab.git
cd sre-agent-lab

# 2. Sign in to Azure
az login
azd auth login

# 3. Create environment
azd env new sre-lab

# 4. (Optional) Set GitHub PAT for bonus scenarios
azd env set GITHUB_PAT <your-github-pat>

# 5. Deploy everything
azd up
# Select your subscription and eastus2 as the region
```

Deployment takes ~8-12 minutes. When complete, you'll see the SRE Agent portal URL and Grubify app URL.

## Post-Deployment: Retry & Update

After the initial `azd up`, you can re-run the post-provision script to update configs without redeploying infrastructure:

```bash
# Re-run full setup (rebuilds container images + re-uploads everything)
./scripts/post-provision.sh

# Skip container image builds (just update KB, subagents, response plan)
./scripts/post-provision.sh --retry

# Skip builds only (still re-creates everything from scratch)
./scripts/post-provision.sh --skip-build
```

### `--retry` vs `--skip-build`

| Flag | Container Build | KB Upload | Subagents | Response Plan |
|------|----------------|-----------|-----------|---------------|
| *(none)* | Yes | Yes | Yes (upsert) | Yes |
| `--skip-build` | **Skip** | Yes | Yes (upsert) | Yes |
| `--retry` | **Skip** | Yes (always) | Yes (upsert) | **Skip if exists** |

**Common scenarios:**
- **Changed a subagent prompt or KB file?** → `./scripts/post-provision.sh --retry`
- **Added a new KB file to `knowledge-base/`?** → `./scripts/post-provision.sh --retry` (auto-discovers all `*.md` files)
- **Changed container app code?** → `./scripts/post-provision.sh` (full rebuild)
- **Response plan 405 error?** → Wait 30s and run `./scripts/post-provision.sh --retry`

## What Gets Deployed

| Component | Azure Service | Purpose |
|-----------|--------------|---------|
| SRE Agent | `Microsoft.App/agents` | AI agent for incident investigation |
| Grubify App | Azure Container Apps | Sample app to monitor |
| Log Analytics | `Microsoft.OperationalInsights/workspaces` | Log storage |
| App Insights | `Microsoft.Insights/components` | Request tracing |
| Alert Rules | `Microsoft.Insights/metricAlerts` | HTTP 5xx and error alerts |
| Managed Identity | `Microsoft.ManagedIdentity` | Reader access for agent |

**Post-provision (automated via REST API):**
- Knowledge base: HTTP error runbook + app architecture doc + incident report template
- Incident handler subagent with diagnostic tools
- Incident response plan for HTTP 500 alerts
- (If GitHub PAT) GitHub MCP connector + code-analyzer + issue-triager subagents + scheduled triage task

## Lab Scenarios

### Scenario 1: IT Operations (No GitHub required)

Break the app and watch the agent investigate:

```bash
./scripts/break-app.sh
```

Then open [sre.azure.com](https://sre.azure.com) → Incidents to watch the agent:
1. Detect the Azure Monitor alert
2. Query Log Analytics for error patterns
3. Reference the HTTP errors runbook
4. Apply remediation (restart/scale)
5. Summarize with root cause and evidence

### Scenario 2: Developer (Requires GitHub)

Ask the agent to search source code for root causes:
- File:line references to problematic code
- Correlation of production errors to code changes
- Suggested fixes with before/after examples

### Scenario 3: Workflow Automation (Requires GitHub)

Create sample support issues and let the agent triage them:

```bash
./scripts/create-sample-issues.sh <owner/repo>
```

The agent classifies issues (Documentation, Bug, Feature Request), applies labels, and posts triage comments following the runbook.

## Adding GitHub Later

If you skipped GitHub during setup:

```bash
export GITHUB_PAT=<your-pat>
./scripts/setup-github.sh
```

## Cleanup

```bash
azd down --purge
```

## Repository Structure

```
sre-agent-lab/
├── azure.yaml                      # azd template
├── infra/
│   ├── main.bicep                  # Subscription-scoped entry point
│   ├── main.bicepparam             # Parameter defaults
│   ├── resources.bicep             # Resource group module orchestrator
│   └── modules/
│       ├── sre-agent.bicep         # Microsoft.App/agents resource
│       ├── identity.bicep          # Managed identity + RBAC
│       ├── monitoring.bicep        # Log Analytics + App Insights
│       ├── container-app.bicep     # Grubify Container App
│       └── alert-rules.bicep       # Azure Monitor alert rules
├── knowledge-base/
│   ├── http-500-errors.md          # HTTP error investigation runbook
│   ├── grubify-architecture.md     # App architecture reference
│   ├── incident-report-template.md # GitHub issue formatting template
│   └── github-issue-triage.md      # Issue triage runbook (GitHub)
├── sre-config/
│   ├── connectors/
│   │   └── github-mcp.yaml        # GitHub MCP connector
│   └── agents/
│       ├── incident-handler-core.yaml   # Core subagent (no GitHub)
│       ├── incident-handler-full.yaml   # Full subagent (with GitHub)
│       ├── code-analyzer.yaml           # Developer persona subagent
│       └── issue-triager.yaml           # Triage persona subagent
├── scripts/
│   ├── post-provision.sh           # azd postprovision hook
│   ├── yaml-to-api-json.py         # Converts YAML agent specs to API JSON
│   ├── break-app.sh                # Fault injection script
│   ├── setup-github.sh             # Add GitHub integration later
│   └── create-sample-issues.sh     # Create triage test issues
└── lab/
    └── skillable-instructions.md   # Skillable lab markdown (copy into Skillable)
```

## Regions

SRE Agent is available in: `eastus2`, `swedencentral`, `australiaeast`

## License

MIT
