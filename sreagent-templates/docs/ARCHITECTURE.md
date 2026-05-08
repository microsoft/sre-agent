# Repository Architecture

## Directory structure

```
sreagent-templates/
│
├── README.md                               ← Quick start (3 use cases)
│
├── bin/                                    ← Scripts you run
│   ├── new-agent.sh                          Create agent from recipe template
│   ├── deploy.sh                             Deploy config directory to Azure
│   ├── export-agent.sh                       Export live agent to config directory
│   └── clone-agent.sh                        Clone agent: export → validate → deploy
│
├── bicep/                                  ← Bicep templates + internal scripts
│   ├── main.bicep                            ARM template (agent + identity + RBAC)
│   ├── agent-core.bicep                      Agent resource + managed identity
│   ├── agent-extensions.bicep                Connectors, tools, skills, subagents, hooks
│   ├── logic-app-bridge.bicep                Webhook bridge for external platforms
│   ├── role-assignments-target.bicep         Reader/Contributor on target RGs
│   ├── assemble-agent.sh                     Internal: YAML config → Bicep JSON
│   └── apply-extras.sh                       Internal: data-plane config (repos, hooks, auth)
│
├── recipes/                              ← Recipe templates
│   ├── azmon-lawappinsights/                     Azure Monitor alert response (AppInsights + LAW)
│   ├── httptrigger-dynatrace/                    Dynatrace MCP + webhook bridge
│   └── pagerduty-law-vmcosmos/                   PagerDuty + VM/CosmosDB investigation
│
└── docs/                                   ← Documentation
    ├── ARCHITECTURE.md                       This file
    ├── CONTRIBUTING.md                       How to add recipes + test
    └── GETTING-STARTED.md                    Getting started guide
```

## Agent config directory layout

Every agent (created, exported, or cloned) uses this structure:

```
<agent-name>/
│
├── agent.json                              ← Identity, region, RGs, access, model, toggles
│   ├── identity.agentName                    Agent name (lowercase, hyphens)
│   ├── identity.resourceGroup                RG for the agent itself
│   ├── identity.subscription                 Subscription ID
│   ├── identity.location                     Region (eastus2/swedencentral/uksouth/australiaeast)
│   ├── identity.targetResourceGroups         RGs the agent monitors
│   ├── access.accessLevel                    Low (read-only) or High (can act)
│   ├── access.actionMode                     Review (human approval) or Automatic
│   ├── model.llmModelName                    Model name (or null for platform default)
│   ├── model.temperature                     LLM temperature
│   ├── model.enableSkills                    Enable skills system
│   ├── featureFlags.enableWorkspaceTools     Workspace tools (file ops, terminal)
│   ├── featureFlags.enableV2AgentLoop        V2 agent loop (checkpoint resilience)
│   └── toggles.*                             Quick-enable for common connectors/features
│
├── connectors.json                         ← Data connectors (3P)
│   └── Array of connector objects              Secrets use ${ENV_VAR} references
│
├── connectors.secrets.env                  ← Actual secrets (GITIGNORED)
│   └── KEY=value pairs                        Bearer tokens, API keys
│
├── .gitignore                              ← Ignores secrets + data/
│
├── config/                                 ← Builder config (YAML files)
│   ├── skills/                               Investigation playbooks
│   │   ├── <name>.yaml                         Metadata: name, description, tool list
│   │   └── <name>.md                           Playbook content (markdown)
│   ├── subagents/                            Specialist agents
│   │   ├── <name>.yaml                         Settings: tools, handoffs, type, temp
│   │   └── <name>.instructions.md              Instructions prompt (markdown)
│   ├── tools/                                Custom tools (KustoTool, Python, HTTP, Link)
│   │   └── <name>.yaml
│   ├── hooks/                                Pre/Post tool use handlers
│   │   └── <name>.yaml
│   ├── common-prompts/                       System prompts
│   │   ├── <name>.yaml                         Metadata
│   │   └── <name>.md                           Prompt text
│   ├── scheduled-tasks/                      Cron-based runs
│   │   └── <name>.yaml
│   ├── incident-filters/                     Alert routing rules
│   │   └── <name>.yaml                         Maps platform + severity → subagent
│   ├── http-triggers/                        Webhook endpoints
│   │   └── <name>.yaml
│   ├── repos/                                Code repo bindings (GitHub/ADO)
│   │   └── <name>.yaml
│   └── plugin-configs/                       Plugin settings
│       └── <name>.yaml
│
├── 1p/                                     ← 1P-only config (only with --include-1p)
│   ├── connectors.json                       IcM, DGrep, GenevaMetrics, Ev2Mcp, S360
│   ├── settings.json                         Cross-tenant adminUsers
│   └── config/                               Skills/subagents/tools using 1P tools
│       ├── skills/
│       ├── subagents/
│       └── tools/
│
└── data/                                   ← Knowledge + memories (with --include-*)
    ├── knowledge/                            Uploaded docs (PDF, MD, images)
    ├── knowledge-items/                      KnowledgeText/File/WebPage content
    ├── synthesized-knowledge/                Learned patterns (.kusto schemas)
    └── repo-instructions/                    Per-repo agent guidance
```

## Connector auth types

| Connector type | Auth method | Who provides credentials | How |
|---|---|---|---|
| AppInsights, LogAnalytics, AzureMonitor | Managed Identity | Auto (agent UAMI) | RBAC on target resource |
| Kusto, KustoClient, AzureMcpKusto | Managed Identity | Auto (agent UAMI) | Viewer role on ADX cluster |
| Mcp, DynatraceMcp, DatadogMcp, etc. | Bearer token | User | `connectors.secrets.env` → `${ENV_VAR}` in connectors.json |
| GitHubOAuth | OAuth browser flow | User | Portal sign-in or `GITHUB_PAT` env var |
| AzureDevOpsOAuth | PAT / AAD / MI | User | `ADO_PAT` or `ADO_USE_AAD=1` or `ADO_USE_MI=1` |
| Teams, Outlook | OAuth via API connection | User | `roles.yaml` api-connection type. deploy.sh creates resource + prints consent URL |
| PagerDuty | API key | User | Portal Incident Platforms page |
| ServiceNow | OAuth / basic auth | User | Portal Incident Platforms page |
| **IcM** (1P) | Cert / Managed Identity | Infra team | Agent UAMI cert or MI access |
| **DGrep** (1P) | Managed Identity | Infra team | Agent UAMI with DGrep access |
| **GenevaMetrics** (1P) | Managed Identity | Infra team | Agent UAMI with MDM reader |
| **Kusto via ADO** (1P cross-tenant) | MI + FIC | Infra team | `ADO_ORG` + `ADO_USE_MI=1` after deploy |

## Model providers

| Provider | 3P | 1P | How selected |
|---|:---:|:---:|---|
| Anthropic (claude-*) | ✅ preferred | ✅ | Portal Settings → Provider dropdown |
| OpenAI/MicrosoftFoundry (gpt-*) | ✅ | ✅ | Portal Settings → Provider dropdown |
| GitHubCopilot (proxy) | ❌ | ✅ | Portal Settings → Provider dropdown + GitHub device flow |

- 3P: can switch provider (Anthropic or OpenAI). Cannot select individual models.
- 1P: can switch provider (all 3) and select individual models (ShowDefaultModelPicker flag).

## How deploy.sh works internally

```
User runs:  ./bin/deploy.sh my-agent/

deploy.sh:
  1. Detects directory input (has agent.json)
  2. Calls bicep/assemble-agent.sh my-agent/
     → Reads agent.json, connectors.json, config/*.yaml
     → Resolves ${ENV_VAR} from connectors.secrets.env
     → Inlines .md content into YAML metadata
     → Produces temp .parameters.json + .extras.json
  3. Runs az deployment sub create with .parameters.json (Bicep)
  4. Runs bicep/apply-extras.sh with .extras.json (data-plane)
  5. Cleans up temp files
```
