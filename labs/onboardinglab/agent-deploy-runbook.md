# Onboarding Lab — agent deployment runbook

This runbook is written **for an Azure SRE Agent to execute**, not for a human shell.
The lab bootstrap script (`scripts/bootstrap-labcreator.ps1`) creates a lab-creator agent and
starts a thread pointing at this file.

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

`--template-file <file>.bicep` works directly: the lab-creator agent allowlists
`*.bicep.azure.com`, so the CLI can fetch the Bicep compiler on first use.

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
| `AGENT_NAME` | Lab agent to create | `onboardinglab-agent` |

`LAB_RG` already exists and your identity has Owner on it. **Its region is irrelevant** — a
resource group's location is only metadata, so an `eastus` group can hold `swedencentral`
resources. Deploy resources to `LOCATION`, not to the group's own region.

Record the resolved values in your first reply so the run is auditable.

---

## Step 1 — Preflight

Confirm the group exists and the region can host the lab.

```bash
az group show --subscription <SUBSCRIPTION> -n <LAB_RG> --query "{name:name,location:location,state:properties.provisioningState}" -o json
```

Then confirm PostgreSQL Flexible Server is actually provisionable — **this is subscription- and
region-specific and is the most common hard blocker**:

```bash
az postgres flexible-server list-skus --subscription <SUBSCRIPTION> --location <LOCATION> --query "[?name=='Standard_B1ms']" -o json
```

An empty result, or a `restrictions` entry with a `reason`, means the region is unusable. Known
restricted regions on some subscriptions: `eastus` ("Provisioning is restricted in this region")
and `eastus2` ("Subscriptions are restricted from provisioning in this region").

Also confirm the region supports the agent resource type:

```bash
az provider show --subscription <SUBSCRIPTION> -n Microsoft.App --query "resourceTypes[?resourceType=='agents'].locations | [0]" -o json
```

**Verify:** group exists, `Standard_B1ms` is listed with no blocking restriction, and `LOCATION`
appears in the agents location list. If the region fails either check, stop and report — do not
silently pick another region.

---

## Step 2 — Deploy the workload

Deploy the resource-group-scoped module directly. Do **not** use
`ticketingapp-source/main.bicep` here: it is subscription-scoped, and `az deployment sub create`
needs subscription-level deployment rights that you do not have.

```bash
az deployment group create \
  --subscription <SUBSCRIPTION> -g <LAB_RG> --name onboardinglab-workload \
  --template-file labs/onboardinglab/ticketingapp-source/modules/workload.bicep \
  --parameters location=<LOCATION> namePrefix=<NAME_PREFIX> \
               tags='{"workload":"onboardinglab"}' \
  --query "{state:properties.provisioningState,outputs:properties.outputs}" -o json
```

This creates the VNet and NSG, Log Analytics, Application Insights, the App Service plan and
Linux web app, the PostgreSQL flexible server with its private DNS zone, and the
`<NAME_PREFIX>-checkout-failures` alert rule. The database fault starts **off**.

Capture these outputs — later steps need them:

- `checkoutAppName`
- `applicationInsightsId`
- `applicationInsightsAppId`
- `networkSecurityGroupName`
- `logAnalyticsWorkspaceId`

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

## Step 5 — Create the agent

The lab owns its agent template at `labs/onboardinglab/infra/modules/sre-agent.bicep`, following
the same pattern as the other labs in this repo. It is resource-group scoped and creates the
managed identity, the RBAC, the agent and the Application Insights connector in a single
deployment. This needs only Owner on `LAB_RG`.

Do **not** deploy `sreagent-templates/bicep/agent-core.bicep` here. Those templates are shared by
every lab, and this lab has a requirement they do not carry: the deployer is a service principal
(you), not a human. The lab template detects the deployer's principal type; the shared one assumes
`User` and fails a managed-identity deployment with `UnmatchedPrincipalType`.

```bash
az deployment group create \
  --subscription <SUBSCRIPTION> -g <LAB_RG> --name onboardinglab-agent \
  --template-file labs/onboardinglab/infra/modules/sre-agent.bicep \
  --parameters agentName=<AGENT_NAME> location=<LOCATION> \
               appInsightsId=<applicationInsightsId> \
               accessLevel=Low actionMode=Review \
               defaultModelProvider=MicrosoftFoundry \
  --query "{state:properties.provisioningState,agentId:properties.outputs.agentId.value,endpoint:properties.outputs.agentEndpoint.value}" -o json
```

This grants the agent's managed identity Reader, Monitoring Reader and Log Analytics Reader on
`LAB_RG`, grants its system-assigned identity the read access the connector needs, and grants you
SRE Agent Administrator on the new agent.

**Verify it is `Succeeded`**, then read the agent back:

```bash
az resource show --subscription <SUBSCRIPTION> -g <LAB_RG> -n <AGENT_NAME> \
  --resource-type Microsoft.App/agents --api-version 2025-05-01-preview \
  --query "{state:properties.provisioningState,running:properties.runningState,endpoint:properties.agentEndpoint}" -o json
```

Record `properties.agentEndpoint` as `AGENT_ENDPOINT`. **Always read the endpoint from the
resource.** It contains service-assigned segments, for example
`onboardinglab-agent--ab12cd34.ef56gh78.swedencentral.azuresre.ai`, and cannot be composed from
the agent name and region.

> The agent resource is created *before* the role assignments, so a failed deployment can still
> leave a healthy agent behind. Check what exists before assuming a clean slate and redeploying.

> `az resource list --resource-type Microsoft.App/agents/connectors` returns `[]` even when the
> connector exists; nested types do not enumerate that way. Verify via the deployment operations
> instead: `az deployment operation group list -g <LAB_RG> --name onboardinglab-agent`.

---

## Step 6 — Apply the data-plane extras

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

## Step 7 — Verify the lab end to end

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
   lands. The lab-creator agent allowlists `*.azurewebsites.net`, so this works:
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

---

## Step 8 — Report

Report back with:

- resource group, region, and the resource names created
- the checkout URL and the agent portal link
  (`https://sre.azure.com/#/agent/<SUBSCRIPTION>/<LAB_RG>/<AGENT_NAME>`)
- confirmation that the alert rule is armed and telemetry is flowing
- anything that failed or was skipped, and why

Leave the database fault **off**. The learner injects it later with:

```bash
pwsh labs/onboardinglab/scripts/fault.ps1 -Action inject \
  -Subscription <SUBSCRIPTION> -ResourceGroup <LAB_RG> \
  -NetworkSecurityGroupName <networkSecurityGroupName> -NamePrefix <NAME_PREFIX>
```

Do not create scheduled tasks, send notifications, or modify anything outside `LAB_RG`.
