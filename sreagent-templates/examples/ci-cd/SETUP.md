# CI/CD Setup Guide

Deploy SRE Agents automatically when you push config changes to GitHub.

## Option 1: GitHub Actions (recommended)

### 1. Create a GitHub repo for your agent config

```bash
# Create repo on GitHub, then:
git clone https://github.com/<your-org>/my-agent-config.git
cd my-agent-config

# Add the recipes repo as a submodule (or copy bin/ + bicep/)
git submodule add https://github.com/coreai-microsoft/sreagent-templates.git templates
```

### 2. Create your agent config

```bash
./templates/bin/new-agent.sh --recipe pagerduty-law-vmcosmos \
  --set agentName=my-pd-agent \
  --set resourceGroup=rg-my-pd \
  --set location=eastus2 \
  --set targetRGs=rg-prod-app \
  --set lawId=/subscriptions/.../workspaces/law-prod \
  --set "pagerdutyApiKey=placeholder" \
  -o agents/prod/

# Remove the placeholder key (secrets go in GitHub, not git)
echo "PAGERDUTY_API_KEY=" > agents/prod/connectors.secrets.env
```

### 3. Add the workflow

```bash
mkdir -p .github/workflows
cp templates/examples/ci-cd/github-actions-deploy.yml .github/workflows/deploy.yml
```

Edit `.github/workflows/deploy.yml` — update the recipe and `--set` flags for your setup.

### 4. Create Azure credentials

You need a service principal with Contributor access on your subscription.

```bash
az ad sp create-for-rbac \
  --name "gh-actions-sre-agent" \
  --role Contributor \
  --scopes /subscriptions/<your-subscription-id> \
  --sdk-auth
```

This outputs a JSON blob. Save it — you'll paste it as a GitHub secret.

> **Microsoft tenants**: if `az ad sp create-for-rbac` fails with "ServiceManagementReference required", your org requires app registrations linked to a service tree node. Options:
> - Use an existing SP that has Contributor on your subscription
> - Use [OIDC / Workload Identity Federation](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure?tabs=azure-portal%2Clinux#use-the-azure-login-action-with-openid-connect) (no secret needed)
> - Use a self-hosted runner with Managed Identity

### 5. Configure GitHub secrets

Go to your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret name | Value | Required |
|---|---|---|
| `AZURE_CREDENTIALS` | JSON output from step 4 | ✅ |
| `PAGERDUTY_API_KEY` | Your PagerDuty integration key | Recipe-specific |
| `DYNATRACE_BEARER_TOKEN` | Your Dynatrace API token | Recipe-specific |

Add non-secret config as **Variables** (same page → Variables tab):

| Variable name | Example | Purpose |
|---|---|---|
| `TARGET_RGS` | `rg-prod-app` | Resource groups to monitor |
| `LAW_ID` | `/subscriptions/.../workspaces/law-prod` | Log Analytics workspace |
| `APP_INSIGHTS_ID` | `/subscriptions/.../components/ai-prod` | App Insights (optional) |

### 6. Push and deploy

```bash
git add .
git commit -m "initial agent config"
git push origin main
```

The workflow triggers on push to `main`. Check **Actions** tab for progress.

### 7. Update config

```bash
# Edit a skill, hook, or response plan
vim agents/prod/config/skills/investigate-vm-issues.md

git add . && git commit -m "update VM investigation skill" && git push
# → workflow re-deploys automatically
```

---

## Option 2: Azure DevOps / EV2

See [ev2-deploy.sh](ev2-deploy.sh) — a shell script that reads all values from environment variables.

```yaml
# ADO pipeline example
trigger:
  branches:
    include: [main]
  paths:
    include: [agents/**]

pool:
  vmImage: ubuntu-latest

steps:
  - task: AzureCLI@2
    inputs:
      azureSubscription: 'my-service-connection'
      scriptType: bash
      scriptPath: templates/examples/ci-cd/ev2-deploy.sh
    env:
      RECIPE: pagerduty-law-vmcosmos
      AGENT_NAME: my-pd-agent
      RESOURCE_GROUP: rg-my-pd
      LOCATION: eastus2
      TARGET_RGS: rg-prod-app
      LAW_ID: $(LAW_ID)
      PAGERDUTY_API_KEY: $(PAGERDUTY_API_KEY)
```

Store secrets in ADO pipeline variables (locked).

---

## Repo structure for multi-agent management

```
my-agent-config/
├── .github/workflows/deploy.yml
├── templates/                    ← submodule: sreagent-templates
├── agents/
│   ├── prod/                     ← production agent config
│   │   ├── agent.json
│   │   ├── connectors.json
│   │   ├── connectors.secrets.env  ← gitignored, secrets in CI
│   │   ├── config/
│   │   └── automations/
│   └── staging/                  ← staging agent config
│       ├── agent.json
│       └── ...
└── .gitignore                    ← *.secrets.env
```

Each push deploys the changed agent(s). The workflow detects which `agents/*/` directory changed and deploys only that one.
