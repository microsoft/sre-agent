# Azure SRE Agent Hands-On Lab

Deploy an Azure SRE Agent connected to a sample application with a single `azd up` command. Watch it diagnose and remediate issues autonomously.

**Learn more:** [What is Azure SRE Agent?](https://sre.azure.com/docs/overview)

## Architecture

<p align="center">
  <img src="docs/architecture.svg" alt="Lab Architecture" width="960"/>
</p>

## Prerequisites

### Required Tools

| Tool | macOS | Windows |
|------|-------|---------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60+ | `brew install azure-cli` | `winget install Microsoft.AzureCLI` |
| [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) 1.9+ | `brew install azd` | `winget install Microsoft.Azd` |
| [Git](https://git-scm.com/) 2.x | `brew install git` | `winget install Git.Git` (includes Git Bash) |
| [Python](https://python.org) 3.10+ | `brew install python3` | `winget install Python.Python.3.12` |

> **Windows note:** After installing Python, disable the Windows Store app aliases:
> **Settings → Apps → Advanced app settings → App execution aliases** → turn OFF `python.exe` and `python3.exe`

### Azure Requirements

- Active Azure subscription
- **Owner** role on the subscription (needed for RBAC role assignments)
- Register the resource provider:
  ```bash
  az provider register -n Microsoft.App --wait
  ```

### Optional (GitHub Integration)

- GitHub account (for code search and issue triage scenarios — uses OAuth sign-in, no PAT needed)
- **Fork the Grubify repo** into your own account before deploying:
  ```bash
  gh auth login
  gh repo fork dm-chelupati/grubify --clone=false
  ```
  Or fork manually at: https://github.com/dm-chelupati/grubify/fork

## Quick Start

### Check prerequisites

Run the prereqs script to verify everything is installed:

```bash
# macOS/Linux
bash scripts/prereqs.sh

# Windows (Git Bash or CMD)
"C:\Program Files\Git\bin\bash.exe" scripts/prereqs.sh
```

### macOS / Linux

```bash
# 1. Clone the repo
git clone https://github.com/microsoft/sre-agent.git
cd sre-agent/labs/starter-lab

# 2. Sign in to Azure
az login
azd auth login

# 3. Create environment and deploy infrastructure
azd env new sre-lab

# 4. (Optional) Set your GitHub username so the agent uses YOUR fork of grubify
azd env set GITHUB_USER <your-github-username>

azd up
# Select your subscription and eastus2 as the region

# 5. Configure the SRE Agent (knowledge base, subagents, connectors)
bash scripts/post-provision.sh
```

### Windows

```cmd
REM 1. Clone the repo
git clone https://github.com/microsoft/sre-agent.git
cd sre-agent\labs\starter-lab

REM 2. Sign in to Azure
az login
azd auth login

REM 3. Create environment and deploy infrastructure
azd env new sre-lab

REM 4. (Optional) Set your GitHub username so the agent uses YOUR fork of grubify
azd env set GITHUB_USER <your-github-username>

azd up

REM 5. Configure the SRE Agent (knowledge base, subagents, connectors)
set PATH=%PATH%;C:\Users\%USERNAME%\AppData\Local\Programs\Python\Python312
"C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh
```

Deployment takes ~8-12 minutes.

## What Gets Deployed

### Azure Infrastructure (via Bicep)

| Resource | Service | Purpose | Docs |
|----------|---------|---------|------|
| SRE Agent | `Microsoft.App/agents` | AI agent for incident investigation | [Overview](https://sre.azure.com/docs/overview) |
| Grubify API | Azure Container Apps | Sample app to monitor | |
| Grubify Frontend | Azure Container Apps | Sample app UI | |
| Log Analytics | `Microsoft.OperationalInsights` | Log storage for KQL queries | [Azure Observability](https://sre.azure.com/docs/capabilities/diagnose-azure-observability) |
| App Insights | `Microsoft.Insights` | Request tracing and exceptions | |
| Alert Rules | `Microsoft.Insights/metricAlerts` | HTTP 5xx and error log alerts | |
| Managed Identity | `Microsoft.ManagedIdentity` | Agent identity for Azure access | [Permissions](https://sre.azure.com/docs/tutorials/agent-config/manage-permissions) |
| Container Registry | `Microsoft.ContainerRegistry` | Grubify container images | |

### RBAC Roles Assigned

| Role | Scope | Purpose |
|------|-------|---------|
| SRE Agent Administrator | Agent resource | User can manage agent via data plane APIs | 
| Reader | Resource group | Agent can read all resources |
| Monitoring Reader | Resource group | Agent can read metrics and alerts |
| Log Analytics Reader | Log Analytics workspace | Agent can query logs via KQL |

See: [Manage Permissions](https://sre.azure.com/docs/tutorials/agent-config/manage-permissions)

### SRE Agent Configuration (via post-provision script)

| Component | Purpose | Docs |
|-----------|---------|------|
| Knowledge Base | HTTP error runbook, app architecture, incident template | [Memory & Knowledge](https://sre.azure.com/docs/concepts/memory) |
| incident-handler subagent | Investigates alerts using logs, metrics, runbooks | [Custom Agents](https://sre.azure.com/docs/concepts/subagents) |
| Response Plan | Routes HTTP 500 alerts to incident-handler | [Response Plans](https://sre.azure.com/docs/capabilities/incident-response-plans) |
| Azure Monitor | Incident platform — alerts flow to the agent | [Incident Platforms](https://sre.azure.com/docs/concepts/incident-platforms) |
| GitHub OAuth connector | Code search and issue management (optional) | [Connectors](https://sre.azure.com/docs/concepts/connectors) |
| code-analyzer subagent | Source code root cause analysis | [Custom Agents](https://sre.azure.com/docs/concepts/subagents) |
| issue-triager subagent | Automated issue triage from runbook | [Custom Agents](https://sre.azure.com/docs/concepts/subagents) |

> **Note on GitHub tools:** GitHub OAuth tools (code search, issue management) are **built-in native tools**, not MCP tools. Once the GitHub OAuth connector is set up, all agents — including subagents — get access to GitHub tools automatically through global settings. No explicit `mcp_tools` assignment is needed in subagent YAML. This is different from MCP connector tools (Datadog, Splunk, etc.) which require explicit `mcp_tools` assignment.
| Scheduled Task | Triage customer issues every 12 hours | [Scheduled Tasks](https://sre.azure.com/docs/capabilities/scheduled-tasks) |
| Code Repo | Agent indexes the Grubify source code | [Deep Context](https://sre.azure.com/docs/concepts/workspace-tools) |

## Post-Deployment

### Re-run the setup script

```bash
# Full re-run (rebuilds container images + re-uploads everything)
./scripts/post-provision.sh

# Skip container image builds (just update KB, subagents, response plan)
./scripts/post-provision.sh --retry

# Windows: run from CMD with Python in PATH
set PATH=%PATH%;C:\Users\%USERNAME%\AppData\Local\Programs\Python\Python312
"C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh --retry
```

### Manual container deploy (Windows fallback)

If the script deploys images but the app still shows the default page:

```cmd
for /f "tokens=*" %a in ('azd env get-value AZURE_CONTAINER_REGISTRY_NAME') do set ACR=%a
for /f "tokens=*" %a in ('azd env get-value CONTAINER_APP_NAME') do set APP=%a
for /f "tokens=*" %a in ('azd env get-value FRONTEND_APP_NAME') do set FE=%a
az containerapp update --name %APP% --resource-group rg-sre-lab --image %ACR%.azurecr.io/grubify-api:latest
az containerapp update --name %FE% --resource-group rg-sre-lab --image %ACR%.azurecr.io/grubify-frontend:latest
```

## Verify Setup

After deployment completes, open your agent at [sre.azure.com](https://sre.azure.com) and click **Full setup**. You should see green checkmarks on:

| Card | Expected Status |
|------|----------------|
| **Code** | ✅ 1 repository |
| **Incidents** | ✅ Connected to Azure Monitor |
| **Azure resources** | ✅ 1 resource group added |
| **Knowledge files** | ✅ 1 file |

> **Checkpoint:** If any card is missing a checkmark, re-run the post-provision script: `bash scripts/post-provision.sh --retry`

Once verified, click **"Done and go to agent"** to open the agent chat and start the team onboarding conversation.

### Team Onboarding

The agent opens a **"Team onboarding"** thread automatically. It will:

1. **Explore your connected context** — reads the code repository, Azure resources, and knowledge files you connected during setup
2. **Interview you about your team** — ask about your team structure, on-call rotation, services you own, and escalation paths

Since the agent already has context from setup, try asking it questions:

> *"What do you know about the Grubify app architecture?"*
>
> *"Summarize the HTTP errors runbook"*
>
> *"What Azure resources are in my resource group?"*

The agent saves your team information to persistent memory and references it in every future investigation.

> **Tip:** Ask *"What should I do next?"* for personalized recommendations based on what's connected.

## Lab Scenarios

### Exploring the Agent (No GitHub required)

After the team onboarding thread, start a **new chat** for each prompt:

**Check deployed resources:**
```
How many container apps are deployed for the Grubify application?
List them with their endpoints.
```

**Search knowledge base:**
```
Using the grubify-architecture document in the knowledge base,
what are the API routes for the Grubify backend API?
Give me a curl command to try one of them.
```

### Scenario 1: IT Operations (No GitHub required)

Break the app and watch the agent investigate:

```bash
./scripts/break-app.sh     # macOS/Linux
# Windows: "C:\Program Files\Git\bin\bash.exe" scripts/break-app.sh
```

While waiting for alerts (5-8 minutes), open the **Grubify frontend** in your browser:
- Try adding an item to your cart
- Notice the app is **slow, unresponsive, or returning errors**
- This confirms the app is broken — compare to how it worked before!

Then open [sre.azure.com](https://sre.azure.com) → **Activities → Incidents** to watch the agent:
1. Detect the Azure Monitor alert
2. Query Log Analytics for error patterns
3. Reference the HTTP errors runbook
4. Apply remediation (restart/scale)
5. Summarize with root cause and evidence

After the agent investigates, ask it to mitigate in the incident thread:
```
Can you mitigate this issue?
```

### Scenario 2: Developer (Requires GitHub)

Start a **new chat**, type `/agent` and select **code-analyzer**, then send:

```
The Grubify API is not responding — specifically the "Add to Cart" 
is failing. Can you investigate, find the root cause in the source 
code and create a GitHub issue with your detailed findings?
```

Compare the GitHub issue created by code-analyzer (with file:line references and fix suggestions) vs the incident-handler's log-only analysis from Scenario 1.

Then ask the agent to fix it:
```
Can you mitigate the Grubify cart API memory leak issue?
```

### Scenario 3: Workflow Automation (Requires GitHub)

Go to **Builder → Scheduled tasks** → find **triage-grubify-issues** → click **Run task now**.

The agent triages open `[Customer Issue]` issues in your grubify fork — classifies them (Bug, Performance, Feature Request, Question), adds labels, and posts a structured triage comment.

## Adding GitHub Later

After initial setup, add GitHub by signing in via the OAuth URL:

```bash
./scripts/setup-github.sh   # macOS/Linux
# Windows: "C:\Program Files\Git\bin\bash.exe" scripts/setup-github.sh
```

## Cleanup

```bash
azd down --purge
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `'bash' is not recognized` (Windows) | Run via: `"C:\Program Files\Git\bin\bash.exe" scripts/post-provision.sh` |
| `Python was not found` (Windows) | Install: `winget install Python.Python.3.12`, disable App execution aliases |
| `curl: error encountered when reading a file` | Python isn't in Git Bash PATH: `export PATH="$PATH:/c/Users/$USER/AppData/Local/Programs/Python/Python312"` |
| `roleAssignments/write` denied | Need Owner role on subscription. Check: `az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv)` |
| `Microsoft.App not registered` | Run: `az provider register -n Microsoft.App --wait` |
| Grubify shows default page after deploy | Run manual deploy commands (see Post-Deployment section above) |
| Post-provision 405 on response plan | Wait 30s and run: `./scripts/post-provision.sh --retry` |

## Regions

SRE Agent is available in: `eastus2`, `swedencentral`, `australiaeast`

## Links

- [Azure SRE Agent Documentation](https://sre.azure.com/docs)
- [Getting Started Guide](https://sre.azure.com/docs/get-started/create-and-setup)
- [Connectors](https://sre.azure.com/docs/concepts/connectors)
- [Custom Agents](https://sre.azure.com/docs/concepts/subagents)
- [Incident Response](https://sre.azure.com/docs/capabilities/incident-response)
- [Azure Observability](https://sre.azure.com/docs/capabilities/diagnose-azure-observability)

## License

MIT
