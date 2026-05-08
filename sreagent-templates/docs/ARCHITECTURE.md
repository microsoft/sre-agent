# Repository Architecture

## Directory structure

```
sreagent-templates/
│
├── README.md                               ← Quick start + recipe table
├── VERSION                                   Semantic version (1.0.0)
├── CHANGELOG.md                              Release notes
├── CONTRIBUTING.md                           How to add recipes + test
│
├── bin/                                    ← Scripts you run
│   ├── new-agent.sh                          Create agent from recipe template
│   ├── deploy.sh                             Deploy config directory (Bicep)
│   ├── deploy-tf.sh                          Deploy config directory (Terraform)
│   ├── export-agent.sh                       Export live agent to config directory
│   ├── clone-agent.sh                        Clone agent: export → validate → deploy
│   ├── diff-agent.sh                         Compare config vs live agent
│   ├── verify-agent.sh                       22-point verification against live agent
│   ├── telemetry.sh                          Optional usage telemetry
│   └── ps/                                 ← PowerShell equivalents
│       ├── New-Agent.ps1
│       ├── Deploy-Agent.ps1
│       ├── Export-Agent.ps1
│       ├── Diff-Agent.ps1
│       ├── Verify-Agent.ps1
│       ├── Check-Prerequisites.ps1
│       └── Telemetry.ps1
│
├── bicep/                                  ← Bicep templates + internal assembly
│   ├── main.bicep                            Entry point (subscription-level)
│   ├── agent-core.bicep                      Agent + identity + LAW + AppInsights + RBAC
│   ├── agent-extensions.bicep                Connectors, tools, skills, subagents, hooks
│   ├── logic-app-bridge.bicep                Webhook bridge for external platforms
│   ├── role-assignments-target.bicep         Reader/Contributor on target RGs
│   ├── assemble-agent.sh                     Internal: YAML config → Bicep parameters JSON
│   ├── Assemble-Agent.ps1                    PowerShell equivalent
│   ├── apply-extras.sh                       Internal: data-plane config (repos, hooks, auth)
│   └── Apply-Extras.ps1                      PowerShell equivalent
│
├── terraform/                              ← Terraform module (azapi provider)
│   ├── main.tf                               Agent + identity + RBAC + connectors
│   ├── variables.tf                          Input variables
│   ├── outputs.tf                            Portal URLs, resource IDs
│   └── versions.tf                           Provider requirements
│
├── recipes/                                ← Recipe templates
│   ├── azmon-lawappinsights/                 Azure Monitor alert response
│   ├── httptrigger-dynatrace/                Dynatrace MCP + webhook bridge
│   └── pagerduty-law-vmcosmos/               PagerDuty + VM/CosmosDB investigation
│
├── tests/                                  ← Dry-run + e2e test suite
│   ├── lib/test-helpers.sh                   Shared test functions
│   ├── test-dry-run-all.sh                   Run all recipe tests
│   ├── test-dry-run-azmon.sh                 Per-recipe: 4 backends × dry-run
│   ├── test-dry-run-dynatrace.sh
│   ├── test-dry-run-pagerduty.sh
│   └── test-e2e-3p.sh                       Full Azure deploy test
│
├── examples/ci-cd/                         ← CI/CD integration examples
│   ├── github-actions-deploy.yml             GitHub Actions workflow
│   └── SETUP.md                              CI/CD setup guide
│
├── docs/                                   ← Documentation
│   ├── ARCHITECTURE.md                       This file
│   ├── GETTING-STARTED.md                    Step-by-step guide
│   └── TEST-PLAN.md                          Testing strategy
│
└── azure.yaml                              ← azd template definition
```

## Agent config directory layout

Every agent (created, exported, or cloned) uses this structure:

```
<agent-name>/
├── agent.json                              ← Identity, region, access, model, toggles
├── connectors.json                         ← Data connectors (AppInsights, LAW, MCP, etc.)
├── connectors.secrets.env                  ← Secrets (GITIGNORED): bearer tokens, API keys
├── .gitignore
├── config/                                 ← Builder config (YAML + markdown)
│   ├── skills/                               Investigation playbooks (.yaml + .md)
│   ├── subagents/                            Specialist agents (.yaml + .instructions.md)
│   ├── tools/                                Custom tools (Kusto, Python, HTTP, Link)
│   ├── hooks/                                Pre/Post tool use handlers
│   ├── common-prompts/                       System prompts (.yaml + .md)
│   ├── scheduled-tasks/                      Cron-based runs
│   ├── incident-filters/                     Alert routing (platform + severity → subagent)
│   ├── http-triggers/                        Webhook endpoints
│   ├── repos/                                Code repo bindings (GitHub/ADO)
│   └── plugin-configs/                       Plugin settings
├── automations/                            ← Incident platform config
│   ├── incident-platforms/                   Platform type (AzureMonitor, PagerDuty, etc.)
│   └── incident-filters/                     Response plans (routing rules)
└── data/                                   ← Knowledge files (optional)
    └── synthesized-knowledge/                Learned patterns
```

## Connector auth types

| Connector type | Auth method | How |
|---|---|---|
| AppInsights, LogAnalytics, AzureMonitor | Managed Identity | RBAC on target resource |
| Kusto, AzureMcpKusto | Managed Identity | Viewer role on ADX cluster |
| Mcp, DynatraceMcp, DatadogMcp | Bearer token | `connectors.secrets.env` |
| GitHubOAuth | OAuth browser flow | Portal sign-in or `GITHUB_PAT` env var |
| PagerDuty | API key | Portal Incident Platforms page |
| ServiceNow | OAuth / basic auth | Portal Incident Platforms page |

## How deploy.sh works

```
User runs:  ./bin/deploy.sh my-agent/

deploy.sh:
  1. Detects directory input (has agent.json)
  2. Calls bicep/assemble-agent.sh my-agent/
     → Reads agent.json, connectors.json, config/*.yaml
     → Resolves ${ENV_VAR} from connectors.secrets.env
     → Inlines .md content into YAML metadata
     → Produces .parameters.json + .extras.json
  3. Runs az deployment sub create with .parameters.json (Bicep)
  4. Runs bicep/apply-extras.sh with .extras.json (data-plane)
  5. Cleans up temp files
```

## Deploy backends

All backends use the same config directory and produce identical agents:

| Backend | Infra deploy | Data-plane | State |
|---|---|---|---|
| Bicep | `az deployment sub create` | `apply-extras.sh` (ARM PUT) | ARM idempotent |
| Terraform | `terraform apply` (azapi) | `apply-extras.sh` (ARM PUT) | TF state per workspace |
| PowerShell | `New-AzDeployment` | `Apply-Extras.ps1` | ARM idempotent |
| azd | `azd up` (preprovision hook) | `apply-extras.sh` via hook | azd env |
