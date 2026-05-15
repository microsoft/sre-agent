# Contributing to Awesome Azure SRE Agent Recipes

Thank you for your interest in contributing! We welcome new recipes, improvements to existing ones, and bug fixes.

## Table of Contents

- [What We Accept](#what-we-accept)
- [What We Don't Accept](#what-we-dont-accept)
- [Quality Guidelines](#quality-guidelines)
- [How to Add a Recipe](#how-to-add-a-recipe)
- [Recipe Structure](#recipe-structure)
- [Required Files Checklist](#required-files-checklist)
- [Testing Your Recipe](#testing-your-recipe)
- [Submitting Your Contribution](#submitting-your-contribution)

## What We Accept

- **New recipes** for incident platforms (PagerDuty, ServiceNow, Grafana, Splunk, etc.)
- **New connector integrations** (MCP servers, Kusto clusters, external APIs)
- **Recipe improvements** (better skills, subagent prompts, additional hooks)
- **Bug fixes** (YAML shape corrections, script fixes, documentation updates)
- **New automation types** (scheduled tasks, HTTP triggers, incident filters)
- **Documentation improvements**

## What We Don't Accept

- **Hardcoded secrets** — tokens, passwords, or API keys must go in `connectors.secrets.env` (gitignored), never in YAML or JSON files
- **Untested recipes** — every recipe must pass `verify-agent.sh` before submission
- **Recipes without `expected-config.json`** — this is the verification spec and is required
- **Incorrect YAML shapes** — all items must match the SRE Agent API shapes (see [Quality Guidelines](#quality-guidelines))
- **Duplicate toggle flags** — connector toggles go in `connectors.json`, not `agent.json`

## Designing a Recipe

A recipe is defined by 5 dimensions. Think through each one for your use case:

### 1. Incident Platform — how does the agent receive incidents?

| Platform | Use when |
|---|---|
| `AzMonitor` | Azure Monitor fired alerts (built-in, no external setup) |
| `PagerDuty` | PagerDuty P1-P5 incidents (needs API key) |
| `ServiceNow` | ServiceNow incidents (needs instance URL + auth) |
| HTTP Trigger | Webhook from any source (Dynatrace, Grafana, custom) |

### 2. Connectors — what data sources does the agent query?

| Connector | Type | Auth | Use for |
|---|---|---|---|
| Log Analytics | Toggle | MI (auto) | KQL queries on Azure logs |
| App Insights | Toggle | MI (auto) | App traces, exceptions, requests |
| Kusto/ADX | Array | MI or FIC | Custom telemetry clusters |
| Dynatrace MCP | Array | Bearer token | Dynatrace problems, entities, metrics |
| Datadog MCP | Array | API key | Datadog monitors, logs, metrics |
| Custom MCP | Array | Varies | Any MCP server endpoint |

### 3. Skills — what investigation playbooks does the agent follow?

Write a skill for each investigation pattern your team repeats:
- `investigate-vm-issues` — CPU spikes, disk full, unresponsive VMs
- `investigate-cosmosdb` — throttling, partition hot spots, RU consumption
- `investigate-http-errors` — 500s, latency spikes, dependency failures
- `triage-app-errors` — group exceptions by type, identify top offenders

Each skill is a `.yaml` (definition) + `.md` (step-by-step instructions).

### 4. Knowledge files — what does the agent need to know?

Put `.md` files in `data/` for anything the agent should reference:
- Architecture diagrams (text description of your system)
- Runbooks for known issues
- Incident response templates
- On-call escalation procedures

### 5. Response plan — how should the agent behave?

| Field | What it controls |
|---|---|
| `priorities` | Which severity levels trigger the agent (Sev0/Sev1, P1/P2) |
| `agentMode` | `Autonomous` (acts on its own) or `Review` (proposes, waits for approval) |
| `customInstructions` | Step-by-step prompt telling the agent what to do |

### Naming Convention

Recipe names follow: `<platform>-<key-connectors>[-variant]`

| Pattern | Example |
|---|---|
| Platform + connectors | `azmon-lawappinsights` |
| Platform + connectors + workload | `pagerduty-law-vmcosmos` |
| Platform + trigger type | `dynatrace-mcp` |

## Quality Guidelines

### YAML Shapes

Every YAML file must match the API shape it targets. Common mistakes:

| Item | Correct Shape | Common Mistake |
|---|---|---|
| Skills | `metadata.name`, `metadata.description`, `metadata.spec.tools`, `skillContent: skills/<name>.md` | Missing `skills/` prefix on skillContent |
| Subagents | `metadata.name`, `spec.instructions: subagents/<name>.instructions.md`, `spec.handoffs: []` | Missing `subagents/` prefix, instructions < 50 chars |
| Hooks | `spec.hook.type`, `spec.hook.prompt`, `spec.hook.matcher` | Using `hookType`/`hookBody` (Bicep shape, not API) |
| Common Prompts | `metadata.name`, `spec.prompt` (inline text) | Referencing .md file instead of inline content |
| Incident Filters | `metadata.name`, `spec.incidentPlatform` (`AzMonitor`, `PagerDuty`, `ServiceNow`) | Using `AzureMonitor` instead of `AzMonitor` |
| Scheduled Tasks | `metadata.name`, `spec.schedule` or `spec.cronExpression`, `spec.prompt` or `spec.agentPrompt` | — |
| Repos | `name`, `spec.url`, `spec.branch` | Using `repoUrl` instead of `url` |

### File References

- Skill content: `skillContent: skills/<name>.md` (not bare `<name>.md`)
- Subagent instructions: `spec.instructions: subagents/<name>.instructions.md`
- The `resolve_file_refs` function requires the directory prefix to locate files

### No Duplicate Resources

- Connector toggles (`enableAppInsightsConnector`, etc.) go in `connectors.json` only
- Do NOT also create connector YAML files for toggle-managed connectors
- Items created by the recipe YAML (hooks, prompts, tasks) must NOT also have Bicep toggle flags

## How to Add a Recipe

### 1. Create the directory

```bash
mkdir -p recipes/my-recipe/config/{skills,subagents,hooks,common-prompts,repos}
mkdir -p recipes/my-recipe/automations/{scheduled-tasks,incident-filters,incident-platforms}
```

### 2. Create required files

See [Required Files Checklist](#required-files-checklist) below.

### 3. Test locally

```bash
# Create agent config
./bin/new-agent.sh --recipe my-recipe \
  --set agentName=test-agent \
  --set resourceGroup=rg-test \
  --set location=eastus2 \
  --set targetRGs=rg-my-app \
  -o /tmp/test-my-recipe \
  --non-interactive

# Copy expected config
cp recipes/my-recipe/expected-config.json /tmp/test-my-recipe/

# Deploy + auto-verify
./bin/deploy.sh /tmp/test-my-recipe/

# Clone test
./bin/export-agent.sh -s $SUB -g rg-test -n test-agent -o /tmp/clone-test
# Edit agent.json (new name/RG/region)
./bin/deploy.sh /tmp/clone-test/
```

### 4. Submit a PR

See [Submitting Your Contribution](#submitting-your-contribution).

## Recipe Structure

```
recipes/my-recipe/
  agent.json              ← Agent identity, settings, prompts for new-agent.sh
  connectors.json         ← Connector toggles + MCP/custom connector entries
  connectors.secrets.env  ← Secret placeholders (gitignored)
  expected-config.json    ← Verification spec (what should be deployed)
  .gitignore              ← Ignores secrets + data/
  config/
    skills/               ← Investigation playbooks (.yaml + .md)
    subagents/            ← Autonomous agents (.yaml + .instructions.md)
    hooks/                ← Governance rules (.yaml)
    common-prompts/       ← System prompts (.yaml)
    repos/                ← Connected code repos (.yaml)
  automations/
    scheduled-tasks/      ← Cron jobs (.yaml)
    incident-filters/     ← Response plans / routing rules (.yaml)
    incident-platforms/   ← Incident platform config (.yaml)
```

## Required Files Checklist

| File | Required | Purpose |
|---|---|---|
| `agent.json` | ✅ | Agent identity, access level, prompts for `new-agent.sh` |
| `connectors.json` | ✅ | Connector toggles + entries |
| `connectors.secrets.env` | ✅ | Secret placeholders (gitignored) |
| `expected-config.json` | ✅ | Verification spec — defines exactly what should be deployed |
| `.gitignore` | ✅ | Must ignore `connectors.secrets.env` and `data/` |
| At least 1 skill | ✅ | `.yaml` + `.md` file pair |
| At least 1 subagent | ✅ | `.yaml` + `.instructions.md` file pair |
| At least 1 hook | Recommended | Governance guardrail |
| At least 1 common prompt | Recommended | Safety rules |
| `automations/incident-platforms/` | If using incidents | Platform type (AzMonitor, PagerDuty, etc.) |
| `automations/incident-filters/` | If using incidents | Response plan routing |

### expected-config.json format

```json
{
  "_scenario": "my-recipe",
  "agent": {
    "accessLevel": "Low",
    "actionMode": "Review",
    "upgradeChannel": "Preview",
    "defaultModelProvider": "Anthropic",
    "incidentPlatform": "AzMonitor"
  },
  "connectors": [
    { "name": "app-insights", "type": "AppInsights" }
  ],
  "skills": ["my-skill-name"],
  "subagents": ["my-subagent-name"],
  "hooks": ["deny-prod-deletes"],
  "commonPrompts": ["safety-rules"],
  "scheduledTasks": ["daily-health-check"],
  "responsePlans": [
    { "name": "my-filter", "handlingAgent": "my-subagent-name" }
  ],
  "repos": ["my-repo"]
}
```

## Testing Your Recipe

Your recipe must pass all three operations with **each deploy backend**:

### Backends

| Backend | Deploy command | Destroy |
|---|---|---|
| Bicep | `deploy.sh dir/` | Delete the resource group |
| Terraform | `deploy-tf.sh dir/` | `deploy-tf.sh dir/ --destroy` |
| azd | `azd up` | `azd down` |

> Recipes don't need backend-specific files. The same `agent.json` + `connectors.json` + `config/` directory works with all backends. The deploy scripts handle conversion internally.

### 1. Create (Bicep)

```bash
./bin/new-agent.sh --recipe my-recipe --set agentName=test -o /tmp/test --non-interactive
./bin/deploy.sh /tmp/test/
./bin/verify-agent.sh $SUB $RG test --expected /tmp/test
```

### 2. Create (Terraform)

```bash
./bin/new-agent.sh --recipe my-recipe --set agentName=test-tf -o /tmp/test-tf --non-interactive
./bin/deploy-tf.sh /tmp/test-tf/
./bin/verify-agent.sh $SUB $RG test-tf --expected /tmp/test-tf
```

### 3. Create (azd)

```bash
azd env new test-azd
azd env set RECIPE my-recipe
azd env set AZURE_AGENT_NAME test-azd
azd env set AZURE_RESOURCE_GROUP rg-test-azd
azd env set AZURE_LOCATION swedencentral
# Set recipe-specific env vars (AZURE_LAW_ID, PAGERDUTY_API_KEY, etc.)
azd up
./bin/verify-agent.sh $SUB rg-test-azd test-azd
```

### 4. Update (idempotent re-deploy)

```bash
# Bicep
./bin/deploy.sh /tmp/test/
# Should skip if no changes, or re-deploy cleanly with --force

# Terraform
./bin/deploy-tf.sh /tmp/test-tf/
# Should show "0 to add, N to change, 0 to destroy"

# azd
azd env select test-azd
azd up
# Should re-deploy cleanly
```

### 5. Clone

```bash
# Export from live agent
./bin/export-agent.sh -s $SUB -g $RG -n test -o /tmp/clone \
  --set agentName=clone --set resourceGroup=rg-clone

# Deploy clone with any backend
./bin/deploy.sh /tmp/clone/           # Bicep
./bin/deploy-tf.sh /tmp/clone/        # Terraform

# azd clone: export to agents/ dir, create new env
./bin/export-agent.sh -s $SUB -g $RG -n test -o agents/clone/ \
  --set agentName=clone --set resourceGroup=rg-clone
azd env new clone
azd env set AZURE_AGENT_NAME clone
azd env set AZURE_RESOURCE_GROUP rg-clone
azd env set AZURE_LOCATION swedencentral
azd up

# Verify clone matches source
./bin/verify-agent.sh $SUB rg-clone clone --expected /tmp/clone
```

## Submitting Your Contribution

1. **Fork** this repository
2. **Create a branch** from `main`
3. **Add your recipe** following the guidelines above
4. **Test** all three operations (create, update, clone)
5. **Submit a pull request** with:
   - Clear title: `recipe: add <recipe-name>`
   - Description of what the recipe deploys
   - Paste of `verify-agent.sh` output showing 0 failures
   - Confirmation you tested create + clone

### PR Checklist

- [ ] `expected-config.json` included
- [ ] All YAML shapes match API (see Quality Guidelines)
- [ ] No hardcoded secrets
- [ ] Skill `.md` files > 50 characters
- [ ] Subagent `.instructions.md` files > 50 characters
- [ ] File references use directory prefix (`skills/`, `subagents/`)
- [ ] `verify-agent.sh` output with 0 failures
- [ ] Tested create + clone operations
- [ ] Dry-run test added: `tests/test-dry-run-<recipe>.sh` (see existing tests for pattern)
- [ ] `CHANGELOG.md` updated under `[Unreleased]` section
- [ ] `VERSION` bumped if needed (MINOR for new recipe, PATCH for fixes)

## Code of Conduct

Please note that this project is maintained with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating you agree to abide by its terms.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
