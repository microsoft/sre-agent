# law-dynatrace-github-httptrigger-prvalidation

PR Deployment Guard: an SRE Agent that reviews every pull request by deploying changes to staging, running canary tests against production baselines via Log Analytics + Dynatrace, and posting a risk assessment as a PR comment — before the code is merged.

The agent receives PR events from GitHub via an HTTP trigger (Logic App webhook bridge), analyzes the diff, deploys to staging, sends synthetic traffic, compares health metrics, and comments on the PR with a LOW / MEDIUM / HIGH / CRITICAL risk rating.

## Prerequisites

- Azure subscription with **production** and **staging** resource groups
- Log Analytics workspace connected to your Container Apps / App Services
- Dynatrace environment with MCP gateway access and API token
- GitHub repo with app source code
- All [CLI tools](../../README.md#prerequisites) installed (`./bin/install-prerequisites.sh --check`)

## Quick Start

### Step 1 — Generate agent config

```bash
./bin/new-agent.sh --recipe law-dynatrace-github-httptrigger-prvalidation --non-interactive \
  --set agentName=contoso-sre \
  --set resourceGroup=rg-sre-contoso \
  --set location=eastus2 \
  --set lawId=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name> \
  --set dtTenant=abc12345 \
  --set dtToken=dt0c01.xxx \
  --set githubRepo=contoso/trading-app \
  --set targetRGs=rg-contoso-prod,rg-contoso-staging \
  -o contoso-sre/
```

### Step 2 — Deploy

| Backend | Command |
|---|---|
| Bicep | `./bin/deploy.sh contoso-sre/` |
| Terraform | `./bin/deploy-tf.sh contoso-sre/` |
| PowerShell | `./bin/ps/Deploy-Agent.ps1 -InputPath contoso-sre/` |

### Step 3 — Set up the Dynatrace secret

```bash
echo "DYNATRACE_BEARER_TOKEN=dt0c01.your-token-here" > contoso-sre/connectors.secrets.env
```

Then redeploy or run `./bin/deploy.sh contoso-sre/` to apply.

### Step 4 — Wire up GitHub PR workflow

Copy the sample workflow to your app repo:

```bash
cp contoso-sre/sample-github-workflow.yml \
  /path/to/your-app/.github/workflows/sre-agent-pr-guard.yml
```

Add the webhook URL as a GitHub secret:

```bash
# Get the Logic App trigger URL from the agent's webhook bridge
WEBHOOK_URL=$(az resource show \
  --resource-group rg-sre-contoso \
  --resource-type Microsoft.Logic/workflows \
  --name <logic-app-name> \
  --query "properties.accessEndpoint" -o tsv)

gh secret set SRE_AGENT_WEBHOOK_URL --repo contoso/trading-app --body "$WEBHOOK_URL"
```

### Step 5 — Test it

Open a PR on your app repo — the GitHub workflow sends the PR event to the agent, which triggers the deployment guard. The agent will:

1. Read the PR diff
2. Capture production baseline metrics from Dynatrace + LAW
3. Deploy changes to staging
4. Send synthetic canary traffic
5. Compare staging health against production
6. Post a risk assessment comment on the PR

## Parameters

| Param | Required | Example | Description |
|---|---|---|---|
| agentName | ✅ | `contoso-sre` | Agent name (lowercase, hyphens) |
| resourceGroup | ✅ | `rg-sre-contoso` | Resource group for the agent |
| location | ✅ | `eastus2` | Azure region |
| targetRGs | ✅ | `rg-contoso-prod,rg-contoso-staging` | Resource groups the agent monitors |
| lawId | ✅ | `/subscriptions/.../workspaces/...` | Log Analytics workspace resource ID |
| dtTenant | ✅ | `abc12345` | Dynatrace tenant ID |
| dtToken | ✅ | `dt0c01.xxx` | Dynatrace API token (stored as secret) |
| githubRepo | ✅ | `contoso/trading-app` | GitHub org/repo |
| modelProvider | | `Anthropic` | AI model provider (Anthropic or Azure OpenAI) |

## What You Get

| Category | Items |
|---|---|
| **Connectors** | Log Analytics, Dynatrace MCP |
| **Skills** | deployment-guard-analysis, investigate-app-errors |
| **Subagents** | deployment-guard, error-investigator |
| **HTTP Trigger** | pr-deployment-guard (receives GitHub PR webhooks) |
| **Hooks** | deny-prod-deletes, require-approval-for-restarts |
| **Common Prompts** | investigation-guidelines, safety-rules |
| **GitHub Repo** | Connected for diff analysis and PR comments |

## Architecture

```
GitHub PR → GitHub Actions workflow → Logic App webhook bridge → SRE Agent HTTP trigger
                                                                        ↓
                                                              deployment-guard subagent
                                                                        ↓
                                                        ┌───────────────┼───────────────┐
                                                        ↓               ↓               ↓
                                                   Read PR diff   Deploy to staging   Query Dynatrace
                                                                        ↓               + LAW baselines
                                                                  Canary traffic
                                                                        ↓
                                                                  Compare health
                                                                        ↓
                                                              Post PR comment with
                                                              risk assessment
```
