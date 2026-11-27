# Awesome Azure SRE Agent Recipes

Production-ready recipes to deploy SRE Agents as code. Pick a recipe, run two commands, deploy.

## Prerequisites

[Azure Cloud Shell](https://shell.azure.com) has everything pre-installed — no setup needed.

For local use, run the install script to check and install all required tools:

```bash
# macOS / Linux
./bin/install-prerequisites.sh

# Windows (PowerShell 7+)
.\bin\ps\Install-Prerequisites.ps1
```

To include optional tools (Terraform, azd):
```bash
./bin/install-prerequisites.sh --all          # everything
./bin/install-prerequisites.sh --terraform    # just Terraform
./bin/install-prerequisites.sh --check        # check only, no install
```

<details>
<summary>Manual install (if you prefer)</summary>

| Tool | Install |
|---|---|
| Azure CLI (`az`) | `brew install azure-cli` or [install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |
| `jq` | `brew install jq` / `apt install jq` / `winget install jqlang.jq` |
| Python 3 + PyYAML | `brew install python3 && pip3 install pyyaml` |
| `curl` | Pre-installed on macOS/Linux |
| Terraform (optional) | `brew install hashicorp/tap/terraform` or [install guide](https://developer.hashicorp.com/terraform/install) |
| azd (optional) | `brew install azd` or [install guide](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd) |

</details>

The exporter installs PyYAML automatically when needed. Use `--no-install-dependencies` to require preinstalled dependencies, or run `./bin/install-prerequisites.sh --python-only` to prepare Python and PyYAML explicitly.

## Quick Start

```bash
git clone https://github.com/microsoft/sre-agent.git
cd sre-agent/sreagent-templates

# Step 0: Install prerequisites (skips already-installed tools)
./bin/install-prerequisites.sh

# Create agent config from a recipe
./bin/new-agent.sh --recipe azmon-lawappinsights --non-interactive \
  --set agentName=my-agent \
  --set resourceGroup=rg-my-agent \
  --set location=swedencentral \
  --set targetRGs=rg-my-workload \
  -o my-agent/

# Deploy (~3 min)
./bin/deploy.sh my-agent/
```

`new-agent` uses `--subscription` when provided, otherwise it uses the active Azure CLI subscription. Region choices are queried for that subscription. See the [supported-regions reference](https://learn.microsoft.com/azure/sre-agent/supported-regions) when preparing non-interactive input.

> **Cloud Shell**: Core deployment works with Cloud Shell's built-in auth. Some data-plane items (hooks, repos) require `az login --scope "https://azuresre.dev/.default"` first, or can be configured later in the [portal](https://sre.azure.com).

### Webhook bridge credentials

Logic App callback URLs contain signed credentials. Templates return only the
Logic App name, and deployment scripts print a retrieval command instead of the
URL. Run that command privately when configuring your external webhook sender,
not in a CI job or a recorded terminal session:

```bash
az rest --method POST \
  --url "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Logic/workflows/<agent-name>-webhook-bridge/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" \
  --query value -o tsv
```

Retrieval requires
`Microsoft.Logic/workflows/triggers/listCallbackUrl/action` on the Logic App;
deployment read access is not sufficient. Pass the result directly to the
external webhook configuration or an approved secret store. Do not log it or
return it as a pipeline output.

**Output compatibility:** `webhookBridgeName` replaces `webhookBridgeUrl` in
[main.bicep](bicep/main.bicep). The standalone
[logic-app-bridge.bicep](bicep/logic-app-bridge.bicep) keeps `logicAppName` but no
longer returns `logicAppCallbackUrl`. Update pipelines that consumed either
removed output to retrieve the credential explicitly with the permission above.

**Existing deployments:** Updating templates does not invalidate previously
exposed URLs or remove old deployment outputs. Rotate the affected Logic App
access keys, update all webhook senders to use the new URLs, and remove affected
deployment history entries (including nested deployments) and retained log or
pipeline artifacts according to your retention requirements. Review both primary
and secondary keys if either could have been exposed. Do not treat history
deletion alone as credential revocation.

Offline regressions for both script variants (no Azure resources are changed):

```bash
bash tests/test-webhook-credentials.sh
pwsh -NoProfile -File tests/Test-WebhookCredentials.ps1
```

## Recipes

| Recipe | Platform | One-line |
|---|---|---|
| [azmon-lawappinsights](recipes/azmon-lawappinsights/) | Azure Monitor | Alert response with AppInsights + Log Analytics, skills, subagents, scheduled tasks |
| [pagerduty-law-vmcosmos](recipes/pagerduty-law-vmcosmos/) | PagerDuty | VM + CosmosDB + HTTP error investigation with knowledge files and skills |
| [dynatrace-mcp](recipes/dynatrace-mcp/) | Dynatrace | Dynatrace MCP connector for investigating application errors |
| [minimal](recipes/minimal/) | (none) | Minimal agent — just infra + RBAC, add your own connectors and skills |

Each recipe README has the full parameter list, example values, and post-deploy steps.

> **Want a recipe for a different platform?** [Open a recipe request](https://github.com/microsoft/sre-agent/issues/new?template=recipe_request.md).

## CLI

| Command | Purpose |
|---|---|
| `new-agent.sh --recipe <name> --set key=val -o dir/` | Create agent config from recipe |
| `deploy.sh dir/` | Deploy (Bicep + data-plane, ~3 min) |
| `deploy.sh dir/ --dry-run` | Assemble only, no ARM call |
| `deploy.sh dir/ --what-if` | ARM validation without deploying |
| `deploy.sh dir/ --force` | Redeploy even if no changes detected |
| `deploy-tf.sh dir/` | Deploy via Terraform |
| `clone-agent.sh --from-agent <name> ...` | Clone: export → validate → deploy |
| `export-agent.sh --set agentName=clone -o dir/` | Export a live agent to config dir |
| `diff-agent.sh $SUB $RG $AGENT dir/` | Compare config vs live agent |
| `verify-agent.sh $SUB $RG $AGENT --expected dir/` | 22-point verification |

## What Gets Deployed

Every recipe deploys these resources (regardless of backend):

| Resource | Description |
|---|---|
| Resource Group | Container for all agent resources |
| User-Assigned Managed Identity (UAMI) | Agent's identity for RBAC |
| Log Analytics Workspace | Agent telemetry (created unless you supply one) |
| Application Insights | Agent monitoring (created unless you supply one) |
| SRE Agent | The agent itself |
| Connectors | Data sources (App Insights, LAW, PagerDuty, Dynatrace, etc.) |
| Skills, Subagents, Tools, Common Prompts | Agent capabilities from the recipe |
| RBAC role assignments | Reader, Log Analytics Reader, Monitoring Reader on target RGs |

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

## Updating Governance Hooks

Hooks require Python 3 and use `failMode: block`. CLI policies inspect
`tool_input.command`; named built-in tools are matched by `tool_name`.
`deny-prod-deletes` denies delete/remove operations whose input contains
`prod`/`prd`. Restart/scale approval and VM/NSG approval are separate
`ask` policies. Production names use substring matching, so `product-dev`
also matches; adapt the naming rule for your environment.
Each approval hook evaluates the same production-removal rule before asking,
so denial does not depend on the ordering of these recipe hooks. This does not
change the platform's behavior for other customer-defined hooks.
Capacity updates (`sku.capacity`, nodepool count limits, worker counts and
replica patches) also request approval. This heuristic checks only the command,
not unrelated input fields. VM/VMSS writes still require review under the VM
policy even when they only update tags.

Built-in matchers use case-sensitive naming patterns rather than an enumerated
tool list: restart/scaling names, NSG modification names in the VM policy, and
`(?:APIM)?RemoveNSGRule.*` for production removal. The scripts use the same
patterns. New names following those conventions are covered automatically;
names outside them (for example `RecycleApplication`) are not. The two CLI
entry points remain explicit because their command arguments determine the action.

AWS checks ordinary tools' operation names (including `batch-delete-*`), not
their arguments. Generic forwarding tools (`call_aws`, `run_script`, ...,
including proxy-prefixed names such as `aws___call_aws`) are parsed for
`aws <service> <operation>` in top-level string arguments: recognized destructive
operations are denied and every other forwarded request asks for approval.
Nested `request` commands are not parsed and therefore require approval.
Ordinary single-component names such as `recommend` are checked as an operation
name rather than rejected for their format.

Check `/api/v2/agent/tools` for actual enabled names. These examples cover only
the naming patterns and recognized commands, not every execution path or complete
shell syntax. Keep least-privilege resource permissions and verify live
approval behavior before relying on the policies.

Existing Agents do not update automatically. Update your own hook YAML,
then reapply and verify (PowerShell equivalents are also available).
Use `apply-extras.sh` directly or `bin/deploy.sh --force` to explicitly reapply
the configuration (`Apply-Extras.ps1` or `Deploy-Agent.ps1 -Force` in PowerShell):

```bash
bash bicep/apply-extras.sh "$SUB" "$RG" "$AGENT" /path/to/updated-agent-config
bash bin/verify-agent.sh "$SUB" "$RG" "$AGENT" --expected /path/to/updated-agent-config
```

Confirm successful data-plane application; a skipped upload is not an update.
Bicep retains `hooks`, `enableDenyProdDeletesHook` and `pendingHooks` as deprecated
compatibility interfaces. `pendingHooks` only returns the caller's entries.
Direct Bicep deployment alone
does not install hooks or convert `enableDenyProdDeletesHook`. Direct Bicep
callers must put the hook in `config/hooks` and then run apply-extras.
The assemblers translate an enabled legacy toggle
into the default `deny-prod-deletes` hook in extras unless a same-name hook
already exists; customer definitions take precedence. Apply the assembled
extras through `apply-extras.sh` or `Apply-Extras.ps1`. Deployment change
detection compares these assembled hook definitions, including matcher, type
and normalized script content, so an added default or changed same-name hook
requires deployment. Identical definitions do not require redeployment.
The toggle has no effect until the assembled extras are actually applied.

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

1. **Incident Platform** — AzMonitor, PagerDuty, ServiceNow
2. **Connectors** — Log Analytics, App Insights, Kusto, MCP (Dynatrace/Datadog/custom)
3. **Skills** — investigation playbooks for your workload (VM, CosmosDB, HTTP errors, etc.)
4. **Knowledge** — runbooks, architecture docs, incident templates
5. **Response Plan** — severity filter, autonomous vs review, customInstructions prompt

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full recipe design guide, naming conventions, and PR guidelines.
