# Deployment Guard Lab

Shift-left reliability with SRE Agent: catch breaking changes in PRs **before** they reach production. This lab sets up an SRE Agent with an HTTP trigger that receives GitHub PR events, deploys changes to staging, compares health metrics against production, and posts a risk assessment as a PR comment.

## What You'll Learn

1. Deploy an SRE Agent with the `law-dynatrace-httptrigger` recipe
2. Wire a GitHub repo to the agent via Logic App webhook bridge
3. Create a PR with a subtle breaking change and watch the agent catch it
4. Understand how deployment guard analysis works end-to-end

## Architecture

```
┌─────────────────┐     PR event     ┌──────────────────┐     webhook     ┌──────────────┐
│   GitHub Repo   │ ──────────────→  │  GitHub Actions  │ ────────────→  │  Logic App   │
│ (contoso-trading)│                  │  (PR workflow)   │                │  (bridge)    │
└─────────────────┘                  └──────────────────┘                └──────┬───────┘
                                                                               │
                                                                          HTTP trigger
                                                                               │
                                                                               ▼
                                                                     ┌──────────────────┐
                                                                     │    SRE Agent      │
                                                                     │  deployment-guard │
                                                                     │    subagent       │
                                                                     └────────┬─────────┘
                                                                              │
                                              ┌───────────────────────────────┼───────────────────────────────┐
                                              │                               │                               │
                                              ▼                               ▼                               ▼
                                     Read PR diff from              Deploy PR changes to            Query Dynatrace +
                                     connected GitHub repo          staging environment              LAW baselines
                                                                              │
                                                                              ▼
                                                                    Run canary traffic
                                                                    for 2-3 minutes
                                                                              │
                                                                              ▼
                                                                    Compare staging vs prod
                                                                    health metrics
                                                                              │
                                                                              ▼
                                                                    Post risk assessment
                                                                    comment on PR
```

## Prerequisites

- Azure subscription with Contributor access
- Dynatrace environment with MCP gateway access
- Tools: `az`, `gh`, `jq`

## Step 0 — Deploy the Sample App (contoso-trading)

Fork and deploy [contoso-trading](https://github.com/dm-chelupati/contoso-trading) to two environments — production and staging. The app is a microservices trading platform (gateway, order-service, payment-service) running on Azure Container Apps.

```bash
# Fork the repo
gh repo fork dm-chelupati/contoso-trading --clone

cd contoso-trading

# Deploy production
azd env new contoso-prod
azd env set AZURE_LOCATION eastus2
azd up

# Deploy staging (same app, separate resource group)
azd env new contoso-staging
azd env set AZURE_LOCATION eastus2
azd up
```

After both environments are running, note:
- **Production RG**: `rg-contoso-prod` (or whatever `azd` created)
- **Staging RG**: `rg-contoso-staging`
- **LAW resource ID**: Find it in the production RG — `az resource list --resource-group rg-contoso-prod --resource-type Microsoft.OperationalInsights/workspaces --query "[0].id" -o tsv`

## Step 1 — Deploy the SRE Agent

Use the `law-dynatrace-httptrigger` recipe from the templates:

```bash
cd sreagent-templates

./bin/new-agent.sh --recipe law-dynatrace-httptrigger --non-interactive \
  --set agentName=deployment-guard-lab \
  --set resourceGroup=rg-deployment-guard-lab \
  --set location=eastus2 \
  --set lawId=/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.OperationalInsights/workspaces/<LAW_NAME> \
  --set dtTenant=<YOUR_DT_TENANT> \
  --set dtToken=<YOUR_DT_TOKEN> \
  --set githubRepo=<YOUR_GITHUB_ORG>/contoso-trading \
  --set targetRGs=rg-contoso-prod,rg-contoso-staging \
  -o deployment-guard-lab/

./bin/deploy.sh deployment-guard-lab/
```

The deploy script will print a GitHub OAuth URL at the end. Open it in your browser and approve the SRE Agent app to connect your fork of contoso-trading.

## Step 2 — Get the Webhook URL

After deployment, the agent has a Logic App webhook bridge. Get the trigger URL:

```bash
# Find the Logic App in the agent's resource group
LOGIC_APP=$(az resource list \
  --resource-group rg-deployment-guard-lab \
  --resource-type Microsoft.Logic/workflows \
  --query "[0].name" -o tsv)

# Get the callback URL for the HTTP trigger
WEBHOOK_URL=$(az rest --method POST \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-deployment-guard-lab/providers/Microsoft.Logic/workflows/${LOGIC_APP}/triggers/manual/listCallbackUrl?api-version=2016-06-01" \
  --query "value" -o tsv)

echo "Webhook URL: $WEBHOOK_URL"
```

## Step 3 — Wire GitHub to the Agent

### Option A: Use the setup script

```bash
cd labs/deployment-guard
bash scripts/setup-github-workflow.sh \
  --repo <YOUR_GITHUB_ORG>/contoso-trading \
  --webhook-url "$WEBHOOK_URL"
```

### Option B: Manual setup

1. Copy the workflow to your contoso-trading fork:

```bash
cp sreagent-templates/recipes/law-dynatrace-httptrigger/data/sample-github-workflow.yml \
  /path/to/contoso-trading/.github/workflows/sre-agent-pr-guard.yml
cd /path/to/contoso-trading
git add .github/workflows/sre-agent-pr-guard.yml
git commit -m "Add SRE Agent PR deployment guard"
git push
```

2. Add the webhook URL as a GitHub secret:

```bash
gh secret set SRE_AGENT_WEBHOOK_URL \
  --repo <YOUR_GITHUB_ORG>/contoso-trading \
  --body "$WEBHOOK_URL"
```

## Step 4 — Test with a Risky PR

Now create a PR that introduces a subtle breaking change:

```bash
cd /path/to/contoso-trading
git checkout main && git pull
git checkout -b config-cleanup

# Rename a database env var — looks like a cleanup but breaks payment-service
sed -i '' 's|DATABASE_URL|DB_CONNECTION_URL|g' payment-service/Program.cs

git add -A
git commit -m "Standardize database env var naming"
git push origin config-cleanup

# Create the PR
gh pr create \
  --title "Standardize database env var naming" \
  --body "Renamed DATABASE_URL to DB_CONNECTION_URL for consistency with other services." \
  --base main \
  --head config-cleanup
```

### What happens next

1. GitHub Actions fires the `sre-agent-pr-guard` workflow
2. The workflow sends the PR event to the Logic App webhook URL
3. The Logic App forwards it to the SRE Agent's HTTP trigger
4. The `deployment-guard` subagent activates and:
   - Reads the PR diff (sees `DATABASE_URL` → `DB_CONNECTION_URL`)
   - Captures production baselines from Dynatrace + LAW
   - Deploys the PR changes to staging
   - Sends canary traffic to staging endpoints
   - Detects that payment-service can't connect to the database (env var mismatch)
   - Posts a **CRITICAL** risk assessment as a PR comment

### Expected PR Comment

The agent should post something like:

> **🔴 CRITICAL Risk — Do not merge**
>
> | Check | Result |
> |---|---|
> | Static Analysis | `DATABASE_URL` renamed to `DB_CONNECTION_URL` in payment-service — env var mismatch with deployment config |
> | Staging Deploy | ✅ Deployed |
> | Canary Tests | ❌ payment-service returning 500 — database connection failed |
> | Health Comparison | Production: 0 errors, Staging: 100% error rate on /api/payments |
>
> **Root Cause**: The `DATABASE_URL` environment variable is defined in the Container App configuration but the code now reads `DB_CONNECTION_URL`. The payment service cannot connect to the database.
>
> **Recommendation**: Either update the Container App env var to `DB_CONNECTION_URL` or revert the code change.

## Step 5 — Clean Up

```bash
# Close the test PR
gh pr close config-cleanup --repo <YOUR_GITHUB_ORG>/contoso-trading --delete-branch

# Delete the agent (optional)
az group delete --name rg-deployment-guard-lab --yes --no-wait
```

## Lab Scenarios

### Scenario 1: Safe change (LOW risk)
Update a log message or comment — agent should report LOW risk.

### Scenario 2: Performance regression (MEDIUM risk)
Add a `Thread.Sleep(500)` or `await Task.Delay(500)` to a hot path — agent should detect latency increase.

### Scenario 3: Breaking change (CRITICAL risk)
Rename an env var or remove a health check endpoint — agent should flag it.

### Scenario 4: Silent data corruption (HIGH risk)
Change a calculation or data mapping — app returns 200 but wrong data. Agent compares response payloads against baselines and catches the difference.

## Troubleshooting

| Issue | Fix |
|---|---|
| Webhook not firing | Check GitHub Actions logs — is `SRE_AGENT_WEBHOOK_URL` secret set? |
| Agent not responding | Check Logic App run history in Azure portal |
| No PR comment | Verify GitHub repo is connected in SRE Agent portal (Settings → Repos) |
| Staging deploy fails | Check agent has `RunAzCliWriteCommands` tool and Contributor role on staging RG |
| Dynatrace queries empty | Verify Dynatrace MCP connector is connected (Settings → Connectors) |
