# Getting Started — External (3P) Teams

Step-by-step guide to create, deploy, and manage an Azure SRE Agent.

## Prerequisites

- Azure subscription with Owner or Contributor access
- Azure CLI installed and logged in (`az login`)
- jq (`brew install jq` or `apt install jq`)
- Python 3 with PyYAML (`pip install pyyaml`)
- At least one resource group to monitor

## Step 1: Clone this repo

```bash
git clone https://github.com/microsoft/sre-agent.git
cd sre-agent/sreagent-templates
```

## Step 2: Choose your path

### Path A: Create a new generic agent

```bash
./bin/new-agent.sh
```

Prompts:
| Prompt | Example | Required |
|--------|---------|:--------:|
| Agent name | `my-sre-agent` | yes |
| Resource group | `sre-agent-rg` | yes |
| Region | `eastus2` | yes |
| Target RGs to monitor | `prod-rg,staging-rg` | yes |
| Application Insights resource ID | `/subscriptions/.../components/my-ai` | no |
| Log Analytics workspace ID | `/subscriptions/.../workspaces/my-law` | no |

### Path B: Create from Dynatrace recipe

```bash
./bin/new-agent.sh --recipe dynatrace-mcp
```

Additional prompts:
| Prompt | Example | Required |
|--------|---------|:--------:|
| Dynatrace tenant ID | `abc12345` (from `https://abc12345.apps.dynatrace.com`) | yes |
| Dynatrace API token | needs `entities.read`, `events.read`, `metrics.read` scopes | yes |
| GitHub repo URL | `https://github.com/myorg/myapp` | no |

### Path C: Clone an existing agent

```bash
./bin/clone-agent.sh \
  --from-agent prod-agent \
  --from-rg prod-rg \
  --from-sub 00000000-0000-0000-0000-000000000000 \
  --agent-name prod-agent-eu \
  --resource-group prod-eu-rg \
  --location swedencentral \
  --target-resource-groups eu-prod-rg
```

## Step 3: Review what was created

```bash
ls my-sre-agent/
```

```
my-sre-agent/
├── agent.json                    ← Edit: name, region, RGs, access level
├── connectors.json               ← Edit: resource IDs, endpoints
├── connectors.secrets.env        ← Edit: bearer tokens, API keys (NEVER commit)
└── config/
    ├── skills/                     Investigation playbooks (.yaml + .md)
    ├── subagents/                  Specialist agents (.yaml + .instructions.md)
    ├── tools/                      Custom tools (KustoTool, Python, HTTP)
    ├── hooks/                      Pre/Post tool use handlers
    ├── common-prompts/             System prompts
    ├── scheduled-tasks/            Cron-based runs
    ├── incident-filters/           Alert routing rules
    ├── http-triggers/              Webhook endpoints
    ├── repos/                      GitHub/ADO code repo bindings
    └── plugin-configs/             Plugin settings
```

### UAMI access (Managed Identity)

The Bicep template creates a User-Assigned Managed Identity (UAMI) and grants it Reader + Log Analytics Reader on your target RGs. Some connectors need additional UAMI access:

| What UAMI needs access to | How to grant | When |
|---|---|---|
| **Target resource groups** | Automatic — Bicep grants Reader + Log Analytics Reader (+ Contributor if accessLevel=High) | During deploy |
| **Target subscriptions** (if monitoring cross-sub) | `az role assignment create --assignee-object-id $UAMI --role Reader --scope /subscriptions/$TARGET_SUB` | After deploy |
| **Kusto/ADX cluster** | `az kusto database add-principal` with Viewer role | After deploy |
| **Teams / Outlook** | API connection created by `roles.yaml`. User signs in via consent URL | After deploy |
| **ADO repos** (via MI) | Federated Identity Credential on UAMI → ADO org. Then `ADO_USE_MI=1` | After deploy |

The UAMI principal ID is printed in the deploy output. To retrieve it later:

```bash
# Get UAMI principal ID from the agent's resource group
az identity list -g <agent-rg> --query "[0].principalId" -o tsv
```

### Adding RGs or subscriptions later

To grant the agent access to additional resource groups or subscriptions after initial deploy:

```bash
UAMI=$(az identity list -g <agent-rg> --query "[0].principalId" -o tsv)

# Add a new resource group
az role assignment create --assignee-object-id $UAMI --assignee-principal-type ServicePrincipal \
  --role Reader --scope /subscriptions/$SUB/resourceGroups/$NEW_RG

# Add Log Analytics Reader on the new RG
az role assignment create --assignee-object-id $UAMI --assignee-principal-type ServicePrincipal \
  --role "Log Analytics Reader" --scope /subscriptions/$SUB/resourceGroups/$NEW_RG

# Add Contributor if agent has accessLevel=High
az role assignment create --assignee-object-id $UAMI --assignee-principal-type ServicePrincipal \
  --role Contributor --scope /subscriptions/$SUB/resourceGroups/$NEW_RG
```

Then update `agent.json` → `identity.targetResourceGroups` to include the new RG and redeploy.

For connectors that use MI, no secrets are needed in files — just RBAC grants.

### Connector credentials

| Connector type | Auth | Where credentials go |
|---|---|---|
| AppInsights, Log Analytics, Azure Monitor | Managed Identity | No secrets — UAMI needs Reader on the resource (auto-granted for target RGs) |
| Kusto/ADX | Managed Identity | No secrets — UAMI needs Viewer on the cluster (grant after deploy) |
| MCP (Dynatrace, Datadog, Splunk, etc.) | Bearer token | `connectors.secrets.env` → `${ENV_VAR}` in `connectors.json` |
| GitHub | OAuth or PAT | Sign in via URL printed by deploy.sh, or set `GITHUB_PAT` env var |
| Azure DevOps | PAT / AAD / MI | `ADO_PAT`, `ADO_USE_AAD=1`, or `ADO_USE_MI=1` env var before deploy |
| Teams / Outlook | OAuth consent | Add to `roles.yaml` as `type: api-connection`. deploy.sh creates the resource and prints consent URL |
| PagerDuty / ServiceNow | Portal setup | Configure via portal Incident Platforms page after deploy |

## Step 4: Validate (dry run)

```bash
./bin/clone-agent.sh --source my-sre-agent/ \
  --agent-name my-sre-agent \
  --resource-group sre-agent-rg \
  --validate-only
```

Checks:
- Region is supported (eastus2, swedencentral, uksouth, australiaeast)
- At least 1 connector configured
- No unfilled `EDIT_ME` placeholders
- Connector auth requirements flagged (which need tokens, which need portal sign-in)
- Model provider detected
- Feature flags checked
- Skill/subagent file references resolve

Fix any errors before deploying. Warnings are advisory.

## Step 5: Deploy

```bash
./bin/deploy.sh my-sre-agent/
```

What happens:
1. Assembles YAML config → Bicep JSON (internal)
2. Runs `az deployment sub create` (creates agent + identity + RBAC)
3. Applies data-plane config (repos, hooks, knowledge, auth)
4. Processes `roles.yaml` (grants RBAC, creates API connections, prints consent URLs)
5. Prints portal links

## Step 6: Post-deploy setup

1. **Open** https://sre.azure.com → find your agent
2. **Features** → enable:
   - `EnableWorkspaceTools` — file ops, terminal, project-aware tools
   - `EnableV2AgentLoop` — checkpoint-based resilience, hook support
3. **Model provider** → switch to Anthropic (preferred) or keep OpenAI
4. **Connectors** → verify all show healthy (green)
5. **GitHub/ADO repos** → sign in via OAuth if prompted
6. **MCP connectors** → verify bearer tokens are valid
7. **Test** → start a conversation, ask it to investigate something in your target RGs

## Common operations

### Export an agent for backup

```bash
./bin/export-agent.sh -s $SUB -g my-rg -n my-agent -o backups/my-agent --include-all
```

### Clone to another region (DR)

```bash
./bin/clone-agent.sh --from-agent prod --from-rg prod-rg --from-sub $SUB \
  --agent-name prod-eu --resource-group prod-eu-rg --location swedencentral
```

### Nightly backup to Git

```bash
./bin/export-agent.sh -s $SUB -g my-rg -n my-agent -o agents/prod --include-all
cd agents/prod && git add -A && git commit -m "backup $(date +%Y-%m-%d)" && git push
```

## Model providers

| Provider | Available | How to switch |
|---|---|---|
| Anthropic (claude-*) | ✅ preferred | Portal → Settings → Provider dropdown |
| OpenAI/MicrosoftFoundry (gpt-*) | ✅ | Portal → Settings → Provider dropdown |

3P agents can switch between Anthropic and OpenAI. Cannot select individual models — provider only.

## Supported regions

`eastus2` · `swedencentral` · `uksouth` · `australiaeast`
