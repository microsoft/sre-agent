# Onboarding Lab — agent deployment runbook

This runbook is written **for an Azure SRE Agent to execute**, not for a human shell.
The bootstrap script (`scripts/bootstrap-agent.ps1`) creates the final onboarding agent with
temporary deployment access and grants the operator SRE Agent Administrator on that agent.
When the Azure CLI can acquire an SRE Agent data-plane token, the script verifies Code Access
and starts a thread pointing at this file. In Azure Cloud Shell environments where that token
audience is unavailable, the operator connects the repository and starts or reuses the thread
in the agent portal with the exact deployment request printed by the script.

Work through the steps in order. Each step states what to run and how to confirm it worked.
Stop and report if a verification fails — do not continue past a failed step.

---

## Before you start — how to run commands here

**Run every Azure command through your Azure CLI tools, never through the workspace terminal.**
`az` in the sandbox terminal is not signed in (`az account show` returns *"Please run az login"*).
Only your `RunAzCliReadCommands` / `RunAzCliWriteCommands` tools carry credentials.

Use the workspace terminal only for non-Azure work: inspecting the repo, building a zip,
running `New-Agent.ps1` / `Assemble-Agent.ps1`, and shaping JSON bodies.

Two consequences:

- Do **not** run `scripts/setup.ps1` or `sreagent-templates/bicep/Apply-Extras.ps1`. Both shell out
  to `az` / `azd` and will fail here. This runbook replaces them.
- `azd` is not installed. Every step below avoids it.

The Bicep files are the IaC source of truth. Deploy the committed
`infra/main.arm.json` artifact generated from `infra/main.bicep`; do not compile Bicep in the
agent sandbox. Downloading the Bicep CLI can exhaust the sandbox filesystem before deployment.

### Re-entrancy

Every step is idempotent. If the thread is interrupted, re-run from the top — ARM deployments,
`az webapp deploy`, and the data-plane `PUT`s all converge to the same state. Before redoing
expensive work, run the step's verification first and skip it if it already passes.

---

## Inputs

Take these from the thread message that started this run. Do not invent values.

| Input | Meaning | Default |
|---|---|---|
| `SUBSCRIPTION` | Subscription ID | from the thread |
| `LAB_RG` | Pre-created lab resource group | `SreAgentOnboardingLabRG` |
| `LOCATION` | Region for all lab resources | `swedencentral` |
| `NAME_PREFIX` | Prefix for workload resources, 3–20 chars, lowercase/digits/hyphen | `flu-lab01` |
| `AGENT_NAME` | Existing final lab agent | `onboardinglab-agent` |
| `AGENT_IDENTITY_NAME` | Existing action identity created by the bootstrap | from the thread |

`LAB_RG` and `AGENT_NAME` already exist. Your action identity has temporary Owner on the group.
Do not create another agent or managed identity. **The resource group's region is irrelevant** — a
resource group's location is only metadata, so an `eastus` group can hold `swedencentral`
resources. Deploy resources to `LOCATION`, not to the group's own region.

Record the resolved values in your first reply so the run is auditable.
Also run `git rev-parse HEAD` in the workspace and record the commit. Do not fetch, pull, or switch
branches during deployment.

---

## Step 1 — Preflight

Confirm the group exists and the region can host the lab.

First verify the non-Azure workspace tools and leave at least 50 MiB free for the application
archive and generated agent configuration:

```bash
for tool in git zip jq python3 pwsh; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
python3 -c "import yaml" || { echo "Missing Python module: PyYAML"; exit 1; }
AVAILABLE_KB=$(df -Pk /tmp | awk 'NR==2 {print $4}')
[ "$AVAILABLE_KB" -ge 51200 ] || { echo "Less than 50 MiB free in /tmp"; exit 1; }
```

Do not install missing tools or dependencies in the sandbox. Stop and report the missing
prerequisite so the lab image or workflow can be corrected.

```bash
az group show --subscription <SUBSCRIPTION> -n <LAB_RG> --query "{name:name,location:location,state:properties.provisioningState}" -o json
```

Then confirm PostgreSQL Flexible Server is actually provisionable — **this is subscription- and
region-specific and is the most common hard blocker**:

```bash
az postgres flexible-server list-skus \
  --subscription <SUBSCRIPTION> \
  --location <LOCATION> \
  --query "[].{reason:reason,versions:supportedServerVersions[].name,skus:supportedServerEditions[].supportedServerSkus[].name}" \
  -o json
```

The SKU names are nested under `supportedServerEditions[].supportedServerSkus`; do not filter
the top-level objects by `name`. Confirm that version `16` and SKU `Standard_B1ms` appear in
the projected response. If either is absent, report any returned `reason` values. Known
restricted regions on some subscriptions include `eastus` ("Provisioning is restricted in this
region") and `eastus2` ("Subscriptions are restricted from provisioning in this region").

Also confirm the region supports the agent resource type:

```bash
az provider show --subscription <SUBSCRIPTION> -n Microsoft.App --query "resourceTypes[?resourceType=='agents'].locations | [0]" -o json
```

**Verify:** group exists, `Standard_B1ms` is listed with no blocking restriction, and `LOCATION`
appears in the agents location list. If the region fails either check, stop and report — do not
silently pick another region.

---

## Step 2 — Deploy the lab infrastructure through Bicep

Deploy the compiled form of the lab's resource-group-scoped Bicep entry point. It composes the
workload module with the existing agent's permanent read-only RBAC and Application Insights
connector. `infra/main.bicep` remains the source of truth; `infra/main.arm.json` is its committed
deployment artifact. Do **not** use `ticketingapp-source/main.bicep`: it is subscription-scoped
and creates its own resource group.

```bash
az deployment group create \
  --subscription <SUBSCRIPTION> -g <LAB_RG> --name onboardinglab \
  --template-file labs/onboardinglab/infra/main.arm.json \
  --parameters location=<LOCATION> namePrefix=<NAME_PREFIX> \
               agentName=<AGENT_NAME> agentIdentityName=<AGENT_IDENTITY_NAME> \
  --query "{state:properties.provisioningState,outputs:properties.outputs}" -o json
```

This creates the VNet and NSG, Log Analytics, Application Insights, the App Service plan and
Linux web app, the PostgreSQL flexible server with its private DNS zone, and the
`<NAME_PREFIX>-checkout-failures` alert rule. It also declares the final agent's permanent
Reader, Monitoring Reader, and Log Analytics Reader roles and connects the workload Application
Insights resource. The database fault starts **off**.

Capture these outputs — later steps need them:

- `checkoutAppName`
- `applicationInsightsId`
- `applicationInsightsAppId`
- `networkSecurityGroupName`
- `logAnalyticsWorkspaceId`
- `agentId`
- `agentEndpoint`

**Verify:** `state` is `Succeeded` and all outputs above are non-empty.

---

## Step 3 — Publish the checkout app

Build the zip in the workspace terminal. Exclude `node_modules` and `test`: the web app has
`SCM_DO_BUILD_DURING_DEPLOYMENT` and `ENABLE_ORYX_BUILD` set, so Oryx installs dependencies
server-side.

```bash
cd labs/onboardinglab/ticketingapp-source/app
zip -r /tmp/checkout-app.zip . -x 'node_modules/*' -x 'test/*' -x '.git/*'
```

Publish it with your CLI tool. The template disables SCM basic auth, so publish profiles do not
work — `az webapp deploy` uses an Entra token and is the supported path:

```bash
az webapp deploy --subscription <SUBSCRIPTION> -g <LAB_RG> -n <checkoutAppName> \
  --type zip --src-path /tmp/checkout-app.zip
```

**Verify:**

```bash
az webapp log deployment show --subscription <SUBSCRIPTION> -g <LAB_RG> -n <checkoutAppName> -o json
```

Look for `"Deployment successful"` and an Oryx build reporting `Errors (0)`.

> Do not use the site's `lastModifiedTimeUtc` as a publish check — OneDeploy does not update it,
> so it will still show the ARM deployment time and look like nothing happened.

---

## Step 4 — Build the agent configuration

These two scripts run in the workspace terminal. They need `jq`, `python3` and PyYAML — **not**
`az` — so they work here.

```bash
cd sreagent-templates/bin/ps
pwsh -NoProfile -Command "./New-Agent.ps1 \
  -RecipePath '../../../labs/onboardinglab/agent-recipe' \
  -Output /tmp/onboardinglab-agent \
  -Subscription '<SUBSCRIPTION>' -NonInteractive -NoTelemetry \
  -Set @{ agentName='<AGENT_NAME>'; resourceGroup='<LAB_RG>'; location='<LOCATION>';
          appInsightsId='<applicationInsightsId>'; appInsightsAppId='<applicationInsightsAppId>';
          modelProvider='MicrosoftFoundry' }"
```

Use `MicrosoftFoundry`. `New-Agent.ps1` warns that Anthropic may be blocked by organizational
data-residency policy in some regions, including `swedencentral`.

Then assemble the deployable artifacts:

```bash
cd ../../bicep
pwsh -NoProfile -Command "./Assemble-Agent.ps1 -ConfigDir /tmp/onboardinglab-agent -Output /tmp/onboardinglab-agent"
```

**Verify:** `/tmp/onboardinglab-agent.extras.json` exists and reports 3 skills, 1 hook,
1 common-prompt, 1 incident-platform and 2 knowledge files.

You only need `extras.json` from here on. The generated `parameters.json` targets the shared
subscription-scoped `main.bicep`. The lab deploys its own agent template instead, so that file
is not used.

---

## Step 5 — Apply the data-plane extras

Bicep does not carry skills, hooks, prompts or knowledge files. Push them from `extras.json` to
the agent data plane using `az rest` with `--resource https://azuresre.dev`.

`GET` goes through your read tool; `PUT` and `PATCH` through your write tool.

Build each request body in the workspace terminal from `/tmp/onboardinglab-agent.extras.json`,
then send it. Routes and body shapes:

| Extra | Route | Body |
|---|---|---|
| skills (3) | `PUT {AGENT_ENDPOINT}/api/v2/extendedAgent/skills/{name}` | `{name, type:"Skill", tags:[], properties:{name, description, tools, skillContent, additionalFiles}}` |
| hooks (1) | `PUT {AGENT_ENDPOINT}/api/v2/extendedAgent/hooks/{name}` | the item's own `name` / `type` / `tags` / `properties`, passed through |
| common prompts (1) | `PUT {AGENT_ENDPOINT}/api/v2/extendedAgent/commonprompts/{name}` | same pass-through (route is lowercase) |
| knowledge (2) | `PUT {AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/{sanitized}` | `{name, type:"KnowledgeItem", tags:[], properties:{dataConnectorType:"KnowledgeFile", dataSource, extendedProperties:{displayName, fileName, fileContent, contentType}}}` |

For skills, `name` and `description` come from the item's `metadata`, and `tools` from
`metadata.spec.tools`.

For knowledge items, `fileContent` is the file's text **base64-encoded**, `contentType` is
`text/markdown` for `.md`, and the resource name is sanitized: lowercase, replace every character
outside `[a-z0-9-]` with `-`, collapse repeats, trim leading/trailing `-`; if longer than 32
characters, truncate to 24 and append `-` plus the first 7 hex characters of the SHA-256 of the
sanitized name.

Example shape of a single call:

```bash
az rest --method put \
  --url "<AGENT_ENDPOINT>/api/v2/extendedAgent/skills/onboarding-health-check" \
  --resource https://azuresre.dev \
  --headers "Content-Type=application/json" \
  --body @/tmp/extras-bodies/skill-onboarding-health-check.json
```

Finally, set the incident platform. This one is an **ARM PATCH on the agent resource**, not a
data-plane call:

```bash
az rest --method patch \
  --url "https://management.azure.com/subscriptions/<SUBSCRIPTION>/resourceGroups/<LAB_RG>/providers/Microsoft.App/agents/<AGENT_NAME>?api-version=2025-05-01-preview" \
  --headers "Content-Type=application/json" \
  --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"}}}'
```

The PATCH briefly moves the agent to `provisioningState: InProgress`. Wait for `Succeeded`
before verifying.

**Verify:** read each item back individually by name, for example
`GET {AGENT_ENDPOINT}/api/v2/extendedAgent/skills/onboarding-health-check`, and confirm the
content length matches the source. The collection endpoint (`.../skills` with no name) may return
empty even when items exist, so do not rely on it.

---

## Step 6 — Verify the lab end to end

1. **Agent** — `provisioningState: Succeeded`, `runningState: Running`,
   `incidentManagementConfiguration.type: AzMonitor`.
2. **RBAC** — the agent's managed identity holds Reader, Monitoring Reader and Log Analytics
   Reader on `LAB_RG`:
   ```bash
   az role assignment list --subscription <SUBSCRIPTION> \
     --scope /subscriptions/<SUBSCRIPTION>/resourceGroups/<LAB_RG> \
     --query "[].{principal:principalId,role:roleDefinitionName}" -o json
   ```
3. **Alert rule** — enabled, severity 2:
   ```bash
   az monitor scheduled-query show --subscription <SUBSCRIPTION> -g <LAB_RG> \
     -n <NAME_PREFIX>-checkout-failures \
     --query "{enabled:enabled,severity:severity,freq:evaluationFrequency,window:windowSize}" -o json
   ```
4. **App and telemetry** — drive a little traffic from the workspace terminal, then confirm it
   lands. The onboarding agent allowlists `*.azurewebsites.net`, so this works:
   ```bash
   B=https://<checkoutAppName>.azurewebsites.net
   curl -sS -o /dev/null -w "GET / %{http_code}\n" $B/
   for i in 1 2 3; do
     curl -sS -m 90 -w " POST /checkout %{http_code}\n" -o /dev/null \
       -X POST -H 'Content-Type: application/json' -d '{"sku":"lab","qty":1}' $B/checkout
   done
   ```
   The **first** `POST /checkout` after a deployment often returns `503` after several seconds —
   that is App Service cold start plus the first private-DNS connection to PostgreSQL, **not** the
   injected fault. Subsequent calls should return `200` with
   `"Database connectivity verified"`.

   Then confirm telemetry, allowing 2–4 minutes for ingestion:
   ```bash
   az monitor app-insights query --subscription <SUBSCRIPTION> \
     --app <applicationInsightsAppId> \
     --analytics-query "requests | where timestamp > ago(30m) | summarize Total=count(), Failed=countif(success==false) by name, resultCode" -o json
   ```
   An empty result immediately after sending traffic is normal — wait and retry before concluding
   anything is broken. Only `POST /checkout` is tracked as a request; `GET /` is not.

5. **Completion marker** — only after every check above and every Step 5 data-plane read-back
   succeeds, record completion through ARM:
   ```bash
   az tag update \
     --resource-id /subscriptions/<SUBSCRIPTION>/resourceGroups/<LAB_RG> \
     --operation Merge \
     --tags onboardingLabDeploymentStatus=verified
   az group show --subscription <SUBSCRIPTION> -n <LAB_RG> \
     --query tags.onboardingLabDeploymentStatus -o tsv
   ```
   The result must be `verified`. Do not write this marker if any deployment or verification
   step failed or was skipped. The external finalizer uses it when the operator's Cloud Shell
   cannot acquire an SRE Agent data-plane token.

---

## Step 7 — Report

Report back with:

- resource group, region, and the resource names created
- the checkout URL and the agent portal link
  (`https://sre.azure.com/agents/subscriptions/<SUBSCRIPTION>/resourceGroups/<LAB_RG>/providers/Microsoft.App/agents/<AGENT_NAME>`)
- confirmation that the alert rule is armed and telemetry is flowing
- anything that failed or was skipped, and why
- confirmation that the operator can now run `bootstrap-agent.ps1 -Finalize`

Leave the database fault **off**. The learner injects it later with:

```bash
pwsh labs/onboardinglab/scripts/fault.ps1 -Action inject \
  -Subscription <SUBSCRIPTION> -ResourceGroup <LAB_RG> \
  -NetworkSecurityGroupName <networkSecurityGroupName> -NamePrefix <NAME_PREFIX>
```

Do not create scheduled tasks, send notifications, or modify anything outside `LAB_RG`.
Do not remove Owner or lower your own access. The operator performs and verifies that boundary
through the bootstrap script after this run completes.
