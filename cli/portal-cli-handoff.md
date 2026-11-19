# Portal and CLI handoff guide

Some Azure SRE Agent setup steps work with `az sre`, some work only in the portal, and some
need the portal first and the CLI after. This guide goes through each official Microsoft Learn
quickstart and tutorial step by step and tells you which to use, with the exact command or the
exact portal page.

Start with [Step 4: Set up incident response](#step-4-set-up-incident-response), a complete
worked example.

Checked on 2026-11-10 against the Learn pages linked below, the page routes in the portal's own
code and this extension. Learn pages change often. If a step here no longer matches its
tutorial, [open an issue](https://github.com/microsoft/sre-agent/issues).

## How to read this guide

Each tutorial step has one of these labels:

| Label | Meaning |
| --- | --- |
| CLI | A terminal command does the whole step: `az sre`, another `az` command, or a REST call the tutorial gives. The command is shown. |
| Portal | Only the portal can do this step. The portal page is shown. |
| Portal, then CLI | Start in the portal, then finish with the commands shown. |
| CLI, then portal | Run the command, then finish in the portal, usually to sign in or to set something the CLI can't. |
| External | The step happens in another service, such as GitHub, PagerDuty or Azure DevOps. |

Steps in the agent's chat, such as asking a question, approving an action or watching an
investigation, are Portal steps: `az sre` has no chat command. Parts of a tutorial that only
describe behavior are left out.

Set these variables once. The commands below use them:

```bash
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
RG="rg-sre-demo"
AGENT="sre-demo"
PORTAL="https://sre.azure.com/agents/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.App/agents/$AGENT"
```

Commands run in your active subscription. Add `--subscription "$SUBSCRIPTION_ID"` to choose
another one. The examples use bash. For PowerShell, see
[JSON quoting on Windows](operations.md#windows-powershell-json-quoting).

## Portal pages

Each page of an agent in the portal has its own URL: `$PORTAL` followed by the path in this
table. For example, this prints the link to the agent's response plans:

```bash
echo "$PORTAL/views/incidents/triggersAndResponsePlans"
```

Write `resourceGroups` exactly like that, with a capital G: the portal reads the agent's
resource ID from the URL case-sensitively.

| Page | Portal menu | Path |
| --- | --- | --- |
| Agent home and chat | Select the agent | None |
| New chat | New chat | `/views/thread/new` |
| Incidents, including Connect an incident platform | Incidents | `/views/incidents` |
| Triggers & response plans | Incidents > Triggers & response plans | `/views/incidents/triggersAndResponsePlans` |
| Scheduled tasks and HTTP triggers | Automation | `/views/automation` |
| Agent Canvas | Build + setup > Workflows > Agent Canvas | `/views/workflows/subAgentBuilder` |
| Code access | Build + setup > Context > Code access | `/views/context/codeAccess` |
| Knowledge sources | Build + setup > Context > Knowledge sources | `/views/context/knowledgeSources` |
| Managed resources | Build + setup > Context > Managed resources | `/views/context/managedResourcesGroups` |
| Connectors | Build + setup > Extensions > Connectors | `/views/extensions/connectors` |
| Tools | Build + setup > Extensions > Tools | `/views/extensions/tools` |
| Skills | Build + setup > Extensions > Skills | `/views/extensions/skills` |
| Skill builder | Build + setup > Extensions > Skill builder | `/views/extensions/skillBuilder` |
| Plugins | Build + setup > Extensions > Plugins | `/views/extensions/plugins` |
| Hooks | Build + setup > Extensions > Hooks | `/views/extensions/globalHooks` |
| Custom instructions | Build + setup > Extensions > Custom instructions | `/views/extensions/customInstructions` |
| Session insights | Build + setup > Monitor > Session insights | `/views/monitor/sessionInsights` |
| Agent consumption | Build + setup > Monitor > Agent consumption | `/views/monitor/agentConsumption` |
| General settings | Settings > General | `/views/settings/general` |

To create an agent in the portal, go to [sre.azure.com](https://sre.azure.com) and select
**Create agent**.

Some Learn pages use older menu names: Builder for Build + setup, Capabilities for Extensions
and Activities > Incidents for Incidents. The older paths still work. For example,
`/views/builder/incidentPlatform` opens the Incidents page.

The paths come from the portal's route table as of 2026-11-10. If one stops working, use the
menu.

## What the CLI does differently

The portal does some setup for you that `az sre` doesn't. These differences decide several of
the labels below.

- **Your role on the agent.** The portal's Create agent wizard makes you SRE Agent
  Administrator on the new agent. `az sre agent create` does that only when you pass
  `--grant-access-to-me admin`. As in the portal, creating the agent and that role assignment
  needs Owner, or Contributor plus User Access Administrator. Without an SRE Agent role,
  commands that call the agent's own API fail with
  `Forbidden(Forbidden: Access denied by PDP)`, even for a subscription Owner. To give yourself
  the role later:

  ```bash
  az sre access grant -g "$RG" --agent-name "$AGENT" --role admin --assignee-me
  ```

  A new role assignment took 10 to 30 seconds to apply in testing.
- **The incident platform.** Learn says Azure Monitor connects automatically when you create an
  agent in the portal. An agent created with `az sre agent create` has no incident platform,
  and `az sre response-plan create` fails until one is set. See
  [Connect your incident platform](#connect-your-incident-platform).
- **The agent's identities.** The portal's wizard sets the agent's knowledge-graph and action
  identities (`properties.knowledgeGraphConfiguration.identity` and
  `properties.actionConfiguration.identity`) to the user-assigned identity it creates.
  `az sre agent create` also creates a user-assigned identity, but sets neither unless you pass
  `--knowledge-graph-configuration` and `--action-configuration`. An `--action-configuration`
  without `identity` gets the user-assigned identity the command creates.
- **Azure resource access.** When you add a subscription, resource group or management group,
  the portal assigns roles to the agent's identity and also adds the scope to the agent's
  managed resources (`properties.knowledgeGraphConfiguration.managedResources`).
  `az sre managed-resource grant` assigns Reader and Monitoring Contributor but doesn't add the
  scope, so the scope doesn't appear on the portal's Managed resources page.
- **Response plans.** A plan's match rules are saved through Azure Resource Manager and its
  instructions through the agent's own API, so you need access to the agent resource and an SRE
  Agent role.

## Step 4: Set up incident response

This is the worked example for
[Step 4: Set up incident response](https://learn.microsoft.com/azure/sre-agent/tutorial-incident-response).
[Automate incident response](https://learn.microsoft.com/azure/sre-agent/automate-incidents) and
[Set up an incident trigger](https://learn.microsoft.com/azure/sre-agent/response-plan) cover the
same flow, and their extra fields are included here.

**Summary:** with Azure Monitor, every setup step works from the CLI except previewing matching
incidents, and you follow incidents in the portal. With PagerDuty or ServiceNow, connect the
platform in the portal, then create and manage response plans from the CLI.

The commands below were tested on a new agent on 2026-11-10.

### Prerequisites

| Step | Label | How |
| --- | --- | --- |
| Create the agent | CLI | `az sre agent create`, see [Create and set up](#create-and-set-up). |
| Give yourself an SRE Agent role | CLI | `az sre access grant -g "$RG" --agent-name "$AGENT" --role admin --assignee-me`, then wait about 30 seconds. Skip this if you created the agent with `--grant-access-to-me admin`. |
| Create the subagent that handles incidents | CLI | `az sre subagent create`, below. |

The subagent's instructions must be at least 50 characters:

```bash
cat > incident-responder.json <<'JSON'
{
  "instructions": "You investigate Azure Monitor alerts for the checkout API. Check recent deployments, error rates and dependencies, then summarize the likely cause with evidence.",
  "handoffDescription": "Use for Azure Monitor incidents on the checkout API."
}
JSON

az sre subagent create -g "$RG" --agent-name "$AGENT" \
  --name incident-responder --value "@incident-responder.json"
```

### Connect your incident platform

| Step | Label | How |
| --- | --- | --- |
| Azure Monitor | CLI | Set the platform with the commands below. |
| Azure Monitor: Monitoring Contributor for the agent's knowledge-graph identity | CLI | The portal does this when that identity is set. Agents created with `az sre agent create` don't have one. Command below. |
| PagerDuty: enter the REST API access key | Portal | Incidents > Connect an incident platform > PagerDuty (`/views/incidents`). |
| ServiceNow: enter the instance URL and credentials | Portal | Incidents > Connect an incident platform > ServiceNow (`/views/incidents`). |
| Disconnect the current platform before you switch | Portal | Incidents, the platform's **...** menu > Disconnect. Response plans are kept. |
| Quickstart response plan option | Portal | Offered when you connect a platform in the portal. Leave it off if you manage plans from the CLI, see [Remove the quickstart plan](#remove-the-quickstart-plan). |

Set Azure Monitor as the incident platform, then check it. The second command prints
`{"type": "AzMonitor"}`:

```bash
az sre agent update -g "$RG" --agent-name "$AGENT" \
  --incident-management-configuration "{type:AzMonitor}"

az sre agent show -g "$RG" --agent-name "$AGENT" \
  --query properties.incidentManagementConfiguration
```

If the agent is linked to Application Insights and `agent update` fails with
`(InvalidApplicationInsightsConfiguration) The AppId and ConnectionString fields must be provided
together.`, run it again with the `--log-configuration` you linked it with, such as
`--log-configuration "@log-configuration.json"`. Azure never returns the stored connection
string, so the CLI can't resend it for you.

When Azure Monitor is the platform, the portal also gives the agent's knowledge-graph identity
Monitoring Contributor on the agent's subscription. Check for that identity with the first
command below. On an agent created with `az sre agent create`, it prints nothing, so skip the
grant. If it prints an identity, grant the role with the second command, which assigns Reader
and Monitoring Contributor:

```bash
az sre agent show -g "$RG" --agent-name "$AGENT" \
  --query properties.knowledgeGraphConfiguration.identity -o tsv

az sre managed-resource grant -g "$RG" --agent-name "$AGENT" \
  --identity "<knowledge-graph-identity>" --target-subscription "$SUBSCRIPTION_ID"
```

The PagerDuty and ServiceNow wizards save two things: the connection, on the agent resource, and
the indexing scope, through the agent's own API. The indexing scope is which PagerDuty services
or which ServiceNow assignment group the agent indexes.
`az sre agent update --incident-management-configuration` sets only the connection, so use the
portal for these two platforms. ServiceNow sign-in methods other than basic authentication,
such as OAuth 2.0, are portal-only.

### Create a response plan

| Step | Label | How |
| --- | --- | --- |
| Agent Canvas > **+** on the subagent > Add incident response plan | CLI | `az sre response-plan create`, below. |
| Name and severity levels | CLI | `--name`, `--display-name` (the name the portal shows, `--name` by default), `--priority` (`Sev0` to `Sev4` for Azure Monitor, `P1`, `P2` and so on for PagerDuty, `1` to `5` for ServiceNow) |
| Impacted service, incident type and title keyword | CLI | `--impacted-service`, `--incident-type`, `--title-contains` |
| Title does not contain | CLI | `--title-not-contains` |
| Response subagent | CLI | `--subagent` |
| Autonomy level, Review recommended | CLI | `--mode review`. Without it the plan is autonomous, which is also the portal's default. |
| Alert reinvestigation cooldown | CLI | `--merge-enabled true --merge-window-hours 3`. The portal allows 1 to 24 hours. |
| Instructions for the subagent | CLI | `--instructions`, `--processing-guide` |
| Preview matching incidents | Portal | Triggers & response plans (`/views/incidents/triggersAndResponsePlans`). The CLI has no preview. |
| Create | CLI | `az sre response-plan create` saves the plan. |

Route Sev0 and Sev1 Azure Monitor alerts about the checkout API to the subagent, in review mode:

```bash
az sre response-plan create -g "$RG" --agent-name "$AGENT" \
  --name sev1-checkout --platform AzMonitor --subagent incident-responder \
  --priority Sev0 Sev1 --title-contains checkout --title-not-contains test \
  --mode review --merge-enabled true --merge-window-hours 3 \
  --instructions "Check deployments from the last 24 hours before anything else."
```

An agent has one incident platform at a time, and `--platform` must match it. If your agent is
connected to PagerDuty instead, match PagerDuty priorities:

```bash
az sre response-plan create -g "$RG" --agent-name "$AGENT" \
  --name p1-pagerduty --platform PagerDuty --subagent incident-responder \
  --priority P1 P2 --mode review
```

Check the plans. The portal shows them on Triggers & response plans and as trigger nodes on
Agent Canvas:

```bash
az sre response-plan list -g "$RG" --agent-name "$AGENT" -o table
az sre response-plan show -g "$RG" --agent-name "$AGENT" --name sev1-checkout
```

### Change a response plan

| Step | Label | How |
| --- | --- | --- |
| Change severities, mode or other settings | CLI | `az sre response-plan update`. A list flag such as `--priority` replaces the whole list. |
| Remove a criterion or the instructions | CLI | `az sre response-plan update` with an empty value, such as `--title-contains=""`, `--priority=""` or `--instructions=""`. Keep the `=`: PowerShell drops a separate `""`. |
| Turn a plan off and on | CLI | `az sre response-plan disable`, `az sre response-plan enable` |
| Delete a plan | CLI | `az sre response-plan delete -g "$RG" --agent-name "$AGENT" --name sev1-checkout --yes` when you no longer need it. Check the exact name first with `az sre response-plan list`. |

```bash
az sre response-plan update -g "$RG" --agent-name "$AGENT" \
  --name sev1-checkout --priority Sev0 Sev1 Sev2
az sre response-plan update -g "$RG" --agent-name "$AGENT" \
  --name sev1-checkout --mode autonomous

az sre response-plan disable -g "$RG" --agent-name "$AGENT" --name sev1-checkout
az sre response-plan enable -g "$RG" --agent-name "$AGENT" --name sev1-checkout
```

### Remove the quickstart plan

If you turned on the quickstart response plan while connecting a platform, it runs alongside
your own plans and can send incidents to the wrong subagent or process them twice. The portal
names it `quickstart_response_plan`, and `az sre response-plan list` and `create` warn when
it's there. Delete it from the CLI, or in the portal on Triggers & response plans:

```bash
az sre response-plan delete -g "$RG" --agent-name "$AGENT" \
  --name quickstart_response_plan --yes
```

### When an incident arrives

| Step | Label | How |
| --- | --- | --- |
| Watch the agent investigate and read its findings | Portal | Incidents (`/views/incidents`), then the incident's thread. `az sre` can't list incidents or threads. |

### Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Incident platform 'AzMonitor' does not match configured incident management type 'None'` | The agent has no incident platform (`'None'`), or `--platform` doesn't match the one it has. | Set the platform as above, or pass the agent's platform in `--platform`. |
| `One or more configured handling agents do not exist.` | `--subagent` names a subagent that doesn't exist. | Check the name with `az sre subagent list -g "$RG" --agent-name "$AGENT"`. |
| `The extension configuration is invalid.` with no reason | Azure doesn't say why, and the CLI can't ask the agent's own API because you have no SRE Agent role. | Give yourself an SRE Agent role, see [Prerequisites](#prerequisites), and run the command again. The error then names the cause. |
| `Forbidden(Forbidden: Access denied by PDP)` | You have no SRE Agent role on the agent. | `az sre access grant -g "$RG" --agent-name "$AGENT" --role admin --assignee-me`, then wait about 30 seconds. |
| `(InvalidApplicationInsightsConfiguration) The AppId and ConnectionString fields must be provided together.` from `agent update` | The agent is linked to Application Insights, and the update sent the link without its connection string, which Azure never returns. | Add the same `--log-configuration` to the command, such as `--log-configuration "@log-configuration.json"`. |
| "Response plan '...' was created, but its instructions were not saved" | The match rules were saved, then the instructions write to the agent's API failed. | Fix the access problem, then run `az sre response-plan update` with only `--instructions` or `--processing-guide`. |

## Get started

These are the pages under Get started in the Learn table of contents, in order.

### Evaluate SRE Agent

Learn: [Evaluate SRE Agent](https://learn.microsoft.com/azure/sre-agent/evaluate).
**Summary:** CLI, except the evaluation ideas that need the agent's chat or the portal.

| Step | Label | How |
| --- | --- | --- |
| Check that a model provider is available in your region | CLI | `az sre agent list-models --location eastus2` |
| Create one agent for one service | CLI | See [Create and set up](#create-and-set-up). |
| Investigate a root cause | Portal | New chat (`/views/thread/new`). |
| Automate alert response | Portal, then CLI | See [Step 4](#step-4-set-up-incident-response). |
| Automate workflows with an HTTP trigger or a scheduled health check | CLI | See [Create an HTTP trigger](#create-an-http-trigger) and [Create scheduled tasks](#create-scheduled-tasks). |
| Automate workflows with a query trigger | Portal | Automation (`/views/automation`). `az sre` has no query triggers. |
| Track usage | CLI | `az sre usage list -g "$RG" --agent-name "$AGENT" --daily true`. Portal: Agent consumption (`/views/monitor/agentConsumption`). |
| When the trial ends, delete the agent to stop the always-on charge | CLI | `az sre agent delete -g "$RG" --agent-name "$AGENT"`. Portal: Settings > General > Delete SRE Agent. |

### Create and set up

Learn: [Create and set up Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/create-and-set-up),
the first step of Get started. Learn's Create an agent page points here.
**Summary:** CLI, except Log Analytics and Application Insights logs, GitHub App and GitLab code
connections, and resource-group permission levels.

| Step | Label | How |
| --- | --- | --- |
| Open the wizard and fill in Basics: subscription, resource group, name, region, model provider | CLI | Commands below. |
| Basics: Application Insights, Create new | CLI | Create a Log Analytics workspace and Application Insights, then link Application Insights with `--log-configuration`, below. Without it the agent works, but has no trace view. |
| Review and Deploy | CLI | `az sre agent create`. Like the wizard, it also creates a user-assigned identity. |
| Deploy: make you SRE Agent Administrator | CLI | `--grant-access-to-me admin` |
| Open Set up your agent | Portal | Opens after deployment. Each card is a row below. |
| Code: GitHub with your account or a PAT | CLI | `az sre repo connect -g "$RG" --agent-name "$AGENT" --repo-url "https://github.com/<org>/<repo>"`. It shows a one-time code and opens GitHub's sign-in page in your browser. To use a PAT instead, set `GITHUB_TOKEN` to it first. |
| Code: Azure DevOps with your account or a managed identity | CLI | `az sre repo connect -g "$RG" --agent-name "$AGENT" --repo-url "https://dev.azure.com/<org>/<project>/_git/<repo>"`. The CLI creates a PAT from your sign-in that expires after 30 days; for a managed identity, add `--devops-auth-type managed-identity --devops-identity <identity-resource-id>`. |
| Code: GitHub App or GitLab | Portal | Code access (`/views/context/codeAccess`). `az sre repo connect` supports GitHub and Azure DevOps tokens and managed identities only. |
| Logs: Azure Data Explorer | CLI | See [Set up Kusto connector](#set-up-kusto-connector). |
| Logs: Log Analytics Workspace or Application Insights | Portal | Connectors (`/views/extensions/connectors`). The wizard also assigns Log Analytics Reader and Monitoring Reader on the resource group and adds it to managed resources. |
| Logs: other providers, such as Datadog or Splunk | Portal | Connectors. |
| Ask "Check for any errors in the last 24 hours" | Portal | New chat. |
| Azure resources: a subscription or management group | CLI | `az sre managed-resource grant -g "$RG" --agent-name "$AGENT" --target-subscription "$SUBSCRIPTION_ID"`, or `--management-group <group>`. It assigns the same roles as the portal, but the scope isn't listed on the Managed resources page. |
| Azure resources: a resource group with Reader or Privileged permissions | Portal | Managed resources (`/views/context/managedResourcesGroups`). The portal assigns roles based on the resource types in the group; `--target-resource-group` assigns only Reader and Monitoring Contributor. |
| Done and go to agent | Portal | Agent home (`$PORTAL`). |

Create the resource group and the agent. List the models first if you're not sure your region
supports the provider:

```bash
az group create --name "$RG" --location eastus2
az sre agent list-models --location eastus2

az sre agent create -g "$RG" --agent-name "$AGENT" --location eastus2 \
  --default-model "{provider:anthropic,name:automatic}" \
  --grant-access-to-me admin
```

To link Application Insights, as the wizard's Create new option does, create a Log Analytics
workspace and Application Insights in the agent's resource group. Pass `--workspace`: without
it, Azure creates a managed workspace in a separate resource group. The `az monitor app-insights`
commands come from the `application-insights` extension, which the CLI offers to install the
first time. Then pass the app ID and connection string in a file, because the connection string
contains characters that inline values can't hold:

```bash
az monitor log-analytics workspace create -g "$RG" --workspace-name "$AGENT-logs" --location eastus2
az monitor app-insights component create -g "$RG" --app "$AGENT-insights" --location eastus2 \
  --workspace "$AGENT-logs"

APP_ID="$(az monitor app-insights component show -g "$RG" --app "$AGENT-insights" --query appId -o tsv)"
CONNECTION_STRING="$(az monitor app-insights component show -g "$RG" --app "$AGENT-insights" --query connectionString -o tsv)"
cat > log-configuration.json <<JSON
{"application-insights-configuration": {"app-id": "$APP_ID", "connection-string": "$CONNECTION_STRING"}}
JSON

az sre agent create -g "$RG" --agent-name "$AGENT" --location eastus2 \
  --log-configuration "@log-configuration.json" --grant-access-to-me admin
```

Keep `log-configuration.json`. Later `az sre agent update` commands on a linked agent need the
same `--log-configuration`; see [Connect your incident platform](#connect-your-incident-platform).

### Team onboarding

Learn: [Team onboarding](https://learn.microsoft.com/azure/sre-agent/team-onboard).
**Summary:** Portal. The whole step happens in the agent's chat.

| Step | Label | How |
| --- | --- | --- |
| Open the Team onboarding thread | Portal | Agent home, Favorites > Team onboarding. |
| Correct what the agent learned about your code and Azure resources | Portal | The Team onboarding thread. |
| Tell the agent about your team | Portal | The Team onboarding thread. |
| Share procedures by attaching a file | Portal | Chat **+** > Attach file. To add the file to the knowledge base instead: `az sre knowledge create -g "$RG" --agent-name "$AGENT" --name runbook --type file --file-path ./runbook.md` |
| Ask "What should I do next?" | Portal | The Team onboarding thread. |

### Complete setup

Learn: [Complete setup](https://learn.microsoft.com/azure/sre-agent/complete-setup).
**Summary:** connecting sources is mostly CLI. The setup page and the chat checks are in the
portal.

| Step | Label | How |
| --- | --- | --- |
| Open the setup page | Portal | Operations hub (`/views/operationsHub`) > Complete setup. |
| Connect code, logs or Azure resources | CLI | Same commands and portal-only exceptions as [Create and set up](#create-and-set-up). |
| Connect incidents | Portal, then CLI | See [Step 4](#step-4-set-up-incident-response). |
| Add knowledge files | CLI | `az sre knowledge create -g "$RG" --agent-name "$AGENT" --name runbook --type file --file-path ./runbook.md` |
| Confirm connectors, knowledge files and Azure resources | CLI | `az sre connector list -g "$RG" --agent-name "$AGENT"`, `az sre knowledge list -g "$RG" --agent-name "$AGENT"`, `az sre managed-resource list -g "$RG" --agent-name "$AGENT"` |
| Confirm code repositories and the Indexed status of knowledge files | Portal | Code access and Knowledge sources. `az sre` can't list repositories. |
| Ask a question only the new source can answer | Portal | New chat. |
| Return to the Team onboarding thread | Portal | Favorites > Team onboarding. |

### Run your first investigation

Learn: [Run your first investigation](https://learn.microsoft.com/azure/sre-agent/first-investigation).
**Summary:** Portal.

| Step | Label | How |
| --- | --- | --- |
| Start a new chat and describe the problem | Portal | New chat (`/views/thread/new`). |
| Watch the agent work and read the diagnosis | Portal | The chat thread. |

### Automate incident response

Learn: [Automate incident response](https://learn.microsoft.com/azure/sre-agent/automate-incidents).
**Summary:** the same flow as [Step 4](#step-4-set-up-incident-response).

| Step | Label | How |
| --- | --- | --- |
| Connect Azure Monitor | CLI | See [Connect your incident platform](#connect-your-incident-platform). |
| Connect PagerDuty or ServiceNow instead | Portal | See [Connect your incident platform](#connect-your-incident-platform). |
| Create a response plan: name, severity, title filters, response subagent, Review mode, reinvestigation cooldown | CLI | `az sre response-plan create`, see [Create a response plan](#create-a-response-plan). |
| Preview matching alerts | Portal | Triggers & response plans (`/views/incidents/triggersAndResponsePlans`). |
| Check that the plan is On and in Review mode | CLI | `az sre response-plan list -g "$RG" --agent-name "$AGENT" -o table` |
| Watch the investigation when an alert fires | Portal | Incidents (`/views/incidents`). |

### Automate workflows

Learn: [Automate workflows](https://learn.microsoft.com/azure/sre-agent/automate-workflows).
**Summary:** Portal, then CLI. The Outlook connector needs the portal. The custom agent and the
scheduled task work from the CLI.

| Step | Label | How |
| --- | --- | --- |
| Add the Office 365 Outlook connector, sign in, set the send operation to Ask and lock the recipient | Portal | Connectors > Add connector > Notification. |
| Create the custom agent with its instructions | CLI | `az sre subagent create`, below. |
| Give the custom agent the connector's email tool | Portal | Agent Canvas, edit the agent > Choose tools. The tool comes from a connector the CLI can't create. |
| Schedule a recurring task | CLI | `az sre automation scheduled-task create`, below. |
| Run the task now and check the run | Portal | Automation (`/views/automation`). `az sre automation scheduled-task show` shows the task definition. |
| Turn off the task | Portal | Automation > Turn off. |
| Delete the task | CLI | `az sre automation scheduled-task delete -g "$RG" --agent-name "$AGENT" --name daily-health-report --yes` |
| Remove the connector | Portal | Connectors. |
| Revoke the Outlook sign-in | External | Your Microsoft account's app permissions. |

```bash
cat > health-check-reporter.json <<'JSON'
{
  "instructions": "You are a health check reporter. Check Azure resource health for my container apps and email the summary to ops@example.com.",
  "handoffDescription": "Use for scheduled health reports on the container apps."
}
JSON

az sre subagent create -g "$RG" --agent-name "$AGENT" \
  --name health-check-reporter --value "@health-check-reporter.json"

az sre automation scheduled-task create -g "$RG" --agent-name "$AGENT" \
  --name daily-health-report \
  --value '{"cronExpression": "0 8 * * *", "agent": "health-check-reporter", "agentPrompt": "Check the health of the resources in my resource group. Verify all apps are running, check CPU and memory metrics over the last hour, and review any recent warning logs. Summarize findings and send the report."}'
```

`cronExpression` is in UTC. The portal's Time of day field shows your browser's time zone, but
it also saves the schedule in UTC.

### Older getting-started pages

The Step 4 incident response tutorial still links to these earlier steps.

#### Add your team's knowledge

Learn: [Add your team's knowledge](https://learn.microsoft.com/azure/sre-agent/first-value).
**Summary:** CLI for uploads. Indexing status and the chat check are in the portal.

| Step | Label | How |
| --- | --- | --- |
| Open Knowledge sources and upload Markdown or text files | CLI | `az sre knowledge create -g "$RG" --agent-name "$AGENT" --name runbook --type file --file-path ./runbook.md`, once per file. |
| Upload a folder | Portal | Knowledge sources (`/views/context/knowledgeSources`) > Add file. |
| Wait for indexing | Portal | Knowledge sources shows the status. |
| Ask what runbooks the agent has and check Sources | Portal | New chat. |

#### Connect source code

Learn: [Connect source code](https://learn.microsoft.com/azure/sre-agent/connect-source-code).
**Summary:** CLI for GitHub and Azure DevOps tokens and managed identities. GitHub Apps,
removing repositories and pull requests from chat are in the portal.

| Step | Label | How |
| --- | --- | --- |
| Add a GitHub repository with OAuth or a PAT | CLI | `az sre repo connect -g "$RG" --agent-name "$AGENT" --repo-url "https://github.com/<org>/<repo>"`. Run it once per repository. To use a PAT, set `GITHUB_TOKEN` to it first. The agent keeps one GitHub credential for all its GitHub repositories, so the PAT must be able to read all of them. |
| Add an Azure DevOps repository with your account, a managed identity or a PAT | CLI | `az sre repo connect -g "$RG" --agent-name "$AGENT" --repo-url "https://dev.azure.com/<org>/<project>/_git/<repo>"`. The PAT the CLI creates expires after 30 days. Add `--devops-auth-type managed-identity --devops-identity <identity-resource-id>` for a managed identity. |
| Add a repository with your GitHub App | Portal | Code access (`/views/context/codeAccess`). |
| Set a display name | CLI | `--display-name`. A separate description needs the portal. |
| Create a pull request from chat | Portal | New chat. |
| Remove a repository | Portal | Code access > Delete. `az sre` can't remove repositories. |
| Update authentication after a PAT expires | CLI | Set `GITHUB_TOKEN` to the new PAT and run `az sre repo connect` again for the same repository URL; it replaces the stored token. For Azure DevOps, run it again before the 30-day PAT expires. |
| Use GitHub as an MCP server with a custom agent instead | CLI | See [Set up MCP connector](#set-up-mcp-connector). |

## Tutorials: Connect

### Share files and screenshots

Learn: [Share files and screenshots](https://learn.microsoft.com/azure/sre-agent/file-attachments-tutorial).
**Summary:** Portal.

| Step | Label | How |
| --- | --- | --- |
| Attach a file, drag and drop one, or paste a screenshot, then ask about it | Portal | New chat (`/views/thread/new`), **+** > Attach file. |
| Save an attached text file to the knowledge base | CLI | `az sre knowledge create -g "$RG" --agent-name "$AGENT" --name runbook --type file --file-path ./runbook.md`. In chat: "Save this to knowledge settings." |

### Set up Teams connector

Learn: [Set up Teams connector](https://learn.microsoft.com/azure/sre-agent/set-up-teams-connector).
**Summary:** Portal. The connector needs a Microsoft Teams sign-in.

| Step | Label | How |
| --- | --- | --- |
| Add a Teams connector | Portal | Connectors (`/views/extensions/connectors`) > Add connector > Send notification. |
| Sign in to Microsoft Teams | Portal | Same wizard. |
| Copy the channel link | External | Microsoft Teams: the channel's **...** > Get link to channel. |
| Paste the channel link, choose the managed identity and add the connector | Portal | Same wizard. |
| Post a test message | Portal | New chat. |
| Edit the connector | Portal | Connectors, the connector's **...** > Edit connector. |
| Delete the connector | CLI | `az sre connector delete -g "$RG" --agent-name "$AGENT" --name <connector> --yes` |

`az sre connector create` doesn't create Teams connectors and points to the portal. The
service creates them as managed connectors, and one created without a Teams sign-in can't
post anything.

## Tutorials: Diagnose

### Run a deep investigation

Learn: [Run a deep investigation](https://learn.microsoft.com/azure/sre-agent/tutorial-deep-investigation).
**Summary:** Portal.

| Step | Label | How |
| --- | --- | --- |
| Turn on deep investigation in chat, ask, approve, watch and turn it off | Portal | New chat > **+** > Deep investigation. |
| Turn on deep investigation in a response plan | Portal | Triggers & response plans (`/views/incidents/triggersAndResponsePlans`). `az sre response-plan` has no option for it. |
| Define the response plan as YAML | Portal | `az sre response-plan` can't set `deepInvestigationEnabled` or `maxAutomatedInvestigationAttempts`. |
| Cancel a deep investigation | Portal | The chat thread. |

### Set up an incident trigger

Learn: [Set up an incident trigger](https://learn.microsoft.com/azure/sre-agent/response-plan).
**Summary:** CLI, except the incidents preview.

| Step | Label | How |
| --- | --- | --- |
| Delete the quickstart response plan if it's on | CLI | See [Remove the quickstart plan](#remove-the-quickstart-plan). |
| Create the response plan: name, severity or priority, impacted service, incident type, title keyword, subagent, autonomy level, cooldown | CLI | See [Create a response plan](#create-a-response-plan). |
| Preview matching incidents | Portal | Triggers & response plans (`/views/incidents/triggersAndResponsePlans`). |
| Turn a plan off and on | CLI | `az sre response-plan disable` and `enable`, see [Change a response plan](#change-a-response-plan). |
| Check the plan in the grid | CLI | `az sre response-plan list -g "$RG" --agent-name "$AGENT" -o table` |
| Edit or delete a plan | CLI | `az sre response-plan update` and `delete`, see [Change a response plan](#change-a-response-plan). |

### Set up PagerDuty indexing

Learn: [Set up PagerDuty indexing](https://learn.microsoft.com/azure/sre-agent/set-up-pagerduty-indexing).
**Summary:** Portal, then CLI for response plans.

| Step | Label | How |
| --- | --- | --- |
| Create a PagerDuty User API key | External | PagerDuty: User Settings > API Access > Create API User Token. A General API key can't acknowledge incidents. |
| Open Incident platform, select PagerDuty and enter the REST API access key | Portal | Incidents > Connect an incident platform (`/views/incidents`). Disconnect any other platform first. |
| Keep or clear the quickstart response plan | Portal | Same wizard. To manage plans from the CLI, clear it and use `az sre response-plan create --platform PagerDuty`. |
| Save and connect | Portal | Same wizard. |
| Check that incidents appear | Portal | Incidents. |
| Edit or disconnect PagerDuty | Portal | Incidents. Response plans are kept when you disconnect. |

`az sre agent update --incident-management-configuration` can store the API key, but not which
services to index. See [Connect your incident platform](#connect-your-incident-platform).

### Set up ServiceNow indexing

Learn: [Set up ServiceNow indexing](https://learn.microsoft.com/azure/sre-agent/setup-servicenow-indexing).
**Summary:** Portal, then CLI for response plans.

| Step | Label | How |
| --- | --- | --- |
| Register an OAuth application, for OAuth 2.0 only | External | ServiceNow: System OAuth > Application Registry. |
| Open Incident platform, select ServiceNow and choose the authentication type | Portal | Incidents > Connect an incident platform (`/views/incidents`). |
| Enter the assignment group | Portal | Same wizard. It's saved through the agent's own API, which `az sre` doesn't call. |
| Enter the basic authentication or OAuth 2.0 details, then save or authorize | Portal | Same wizard. |
| Keep or clear the quickstart response plan | Portal | Same wizard. |
| Check that incidents appear | Portal | Incidents. |
| Edit or disconnect ServiceNow | Portal | Incidents. |
| Update incident fields during an investigation | Portal | The incident's thread. |

### Manage permissions

Learn: [Manage permissions](https://learn.microsoft.com/azure/sre-agent/manage-permissions).
**Summary:** Portal for resource groups and permission levels. CLI for subscription access.

| Step | Label | How |
| --- | --- | --- |
| Add or remove managed resource groups | Portal | Managed resources (`/views/context/managedResourcesGroups`). `az sre managed-resource grant --target-resource-group` assigns only Reader and Monitoring Contributor, and the group isn't listed on this page. |
| Set the permission level to Reader or Privileged | Portal | Managed resources. |
| Grant subscription-level Reader access | CLI | Command below. |
| Ask "What Azure resources can you see?" | Portal | New chat. To list the agent identity's role assignments: `az sre managed-resource list -g "$RG" --agent-name "$AGENT"` |

`managed-resource grant` assigns Reader and Monitoring Contributor, one more role than the
tutorial's Reader. Like the portal, it targets the identity the agent is configured to use for
managed resources; pass `--identity system` or a user-assigned identity's resource ID to
target another one:

```bash
az sre managed-resource grant -g "$RG" --agent-name "$AGENT" \
  --target-subscription "$SUBSCRIPTION_ID"
```

### Set up incident response

Learn: [Step 4: Set up incident response](https://learn.microsoft.com/azure/sre-agent/tutorial-incident-response).
See the worked example, [Step 4: Set up incident response](#step-4-set-up-incident-response).

## Tutorials: Act

### Create scheduled tasks

Learn: [Create scheduled tasks](https://learn.microsoft.com/azure/sre-agent/create-scheduled-task).
**Summary:** CLI, except message grouping, run history and Refine with AI.

| Step | Label | How |
| --- | --- | --- |
| Open Automation and create a scheduled task: name, task details, frequency, time of day | CLI | `az sre automation scheduled-task create`, below. |
| Leave the response subagent, model tier and autonomy level at their defaults | CLI | Leave those fields out. To hand the task to a subagent, add `"agent": "<subagent>"`. Without `agentMode` the task runs autonomously, even when the agent runs in review mode; add `"agentMode": "review"` to have its actions wait for approval. |
| Message grouping for updates | Portal | To change it from the default, use Automation > Edit. The CLI's task fields don't include it. |
| Weekly, monthly or custom cron schedules | CLI | `cronExpression`, always in UTC. |
| Limit how long it runs with Repeat until or a run limit | CLI | `endTime` (an ISO 8601 date-time) or `maxExecutions`. |
| Check that the task exists | CLI | `az sre automation scheduled-task show -g "$RG" --agent-name "$AGENT" --name daily-health-check` |
| Review the run history and threads | Portal | Automation (`/views/automation`) > the task name. |
| Edit a task | CLI | Run the `create` command again with `--overwrite true`. |
| Refine the task details with AI | Portal | Automation > Edit > Refine with AI. |
| Create the task from Agent Canvas for a custom agent | CLI | The same command with `"agent"` set to the custom agent. |

```bash
az sre automation scheduled-task create -g "$RG" --agent-name "$AGENT" \
  --name daily-health-check \
  --value '{"cronExpression": "0 9 * * *", "agentPrompt": "Check Azure Resource Health for all resources in prod-rg. Summarize healthy, warning, and critical counts."}'
```

### Create an HTTP trigger

Learn: [Create an HTTP trigger](https://learn.microsoft.com/azure/sre-agent/create-http-trigger).
**Summary:** CLI to create the trigger, get its URL and call it. Message grouping and Run now are
in the portal.

| Step | Label | How |
| --- | --- | --- |
| Open Automation and create the HTTP trigger: name, details with `{payload.*}` placeholders, Autonomous | CLI | `az sre automation http-trigger create`, below. |
| Message grouping: New chat thread for each run | Portal | Automation > the trigger > Edit. The CLI's trigger fields don't include it. |
| Copy the trigger URL | CLI | `az sre automation http-trigger show -g "$RG" --agent-name "$AGENT" --name container-app-compliance --query properties.value.triggerUrl -o tsv` |
| Run the trigger now | Portal | Automation > the trigger > Run trigger now. |
| Call the trigger from the command line | CLI | `az sre automation http-trigger invoke -g "$RG" --agent-name "$AGENT" --name container-app-compliance --payload "@payload.json"`, which calls the trigger URL with your Azure CLI sign-in. |
| Call the trigger from your pipeline | External | Your CI/CD pipeline. Store the trigger URL as a secret. |
| Delete the trigger | CLI | `az sre automation http-trigger delete -g "$RG" --agent-name "$AGENT" --name container-app-compliance --yes` |

```bash
cat > container-app-compliance.json <<'JSON'
{
  "agentPrompt": "A new container app revision was deployed. Run a compliance check on the app. Verify that resource limits (CPU/memory), health probes, ingress configuration, and scaling rules are configured correctly. Report any issues found. App details: {payload.app_name} in resource group {payload.resource_group}. Revision: {payload.revision_name}.",
  "agentMode": "autonomous"
}
JSON

az sre automation http-trigger create -g "$RG" --agent-name "$AGENT" \
  --name container-app-compliance --value "@container-app-compliance.json"
```

## Tutorials: Extend

### Configure agent hooks

Learn: [Configure agent hooks](https://learn.microsoft.com/azure/sre-agent/tutorial-agent-hooks).
**Summary:** CLI. The tutorial itself uses the agent's REST API from a terminal; testing is in
the portal.

| Step | Label | How |
| --- | --- | --- |
| Find the agent's API URL | CLI | `az sre agent show -g "$RG" --agent-name "$AGENT" --query properties.agentEndpoint -o tsv`, instead of the browser's developer tools. |
| Get an access token | CLI | The tutorial's `az account get-access-token` command. |
| Create a custom agent with a Stop hook, then add PostToolUse hooks | CLI | The tutorial's `curl` commands. For hooks on the whole agent, use `az sre hook create`, see [Create and manage hooks](#create-and-manage-hooks). |
| Test the hooks in the playground | Portal | Agent Canvas (`/views/workflows/subAgentBuilder`) > Test playground. |

### Create and manage hooks

Learn: [Create and manage hooks in the portal](https://learn.microsoft.com/azure/sre-agent/create-manage-hooks-ui).
**Summary:** CLI for hooks on the whole agent. Hooks on one subagent and per-thread toggles are
in the portal.

| Step | Label | How |
| --- | --- | --- |
| Create a Stop hook that checks responses (prompt hook) | CLI | `az sre hook create`, below. |
| Create a PostToolUse hook that blocks dangerous commands (Python command hook) | CLI | `az sre hook create`, below. |
| Test the hooks | Portal | New chat (`/views/thread/new`). |
| Edit a hook | CLI | Run `az sre hook create` again with `--overwrite true`. |
| Delete a hook | CLI | `az sre hook delete -g "$RG" --agent-name "$AGENT" --name require-table-format --yes` |
| Add a Stop hook to one subagent | Portal | Agent Canvas, the subagent > Manage Hooks. `az sre subagent create --pre-tool-use-script-file` adds only a script that runs before every tool call. |
| Turn hooks on or off for one thread | Portal | The chat's **+** > Manage Hooks. |

```bash
cat > require-table-format.json <<'JSON'
{
  "eventType": "Stop",
  "activationMode": "always",
  "description": "Require comparisons to be formatted as a table",
  "hook": {
    "type": "prompt",
    "prompt": "If the response compares options, check that the comparison is a markdown table. Reply {\"ok\": true} if it is, otherwise {\"ok\": false, \"reason\": \"Format the comparison as a markdown table.\"}",
    "timeout": 30,
    "failMode": "Allow",
    "maxRejections": 3
  }
}
JSON

az sre hook create -g "$RG" --agent-name "$AGENT" \
  --name require-table-format --value "@require-table-format.json"

cat > block-dangerous-commands.json <<'JSON'
{
  "eventType": "PostToolUse",
  "activationMode": "always",
  "description": "Block dangerous shell commands",
  "hook": {
    "type": "command",
    "matcher": "Bash|ExecuteShellCommand",
    "script": "#!/usr/bin/env python3\nimport json, re, sys\ncommand = json.load(sys.stdin).get('tool_input', {}).get('command', '')\nblocked = re.search(r'\\brm\\s+-rf\\b|\\bsudo\\b|\\bchmod\\s+777\\b', command)\nprint(json.dumps({'decision': 'block', 'reason': 'Blocked by policy'} if blocked else {'decision': 'allow'}))\n",
    "timeout": 30,
    "failMode": "Block"
  }
}
JSON

az sre hook create -g "$RG" --agent-name "$AGENT" \
  --name block-dangerous-commands --value "@block-dangerous-commands.json"
```

### Test a tool in the playground

Learn: [Test a tool in the playground](https://learn.microsoft.com/azure/sre-agent/test-tool-playground).
**Summary:** Portal.

| Step | Label | How |
| --- | --- | --- |
| Open the playground and select a tool | Portal | Agent Canvas (`/views/workflows/subAgentBuilder`) > Test playground. |
| Test a Kusto tool or a system tool | Portal | Same page. |

### Create a Python tool

Learn: [Create a Python tool](https://learn.microsoft.com/azure/sre-agent/create-python-tool).
**Summary:** Portal to generate and test the code. With your own code, the CLI creates and
edits the tool.

| Step | Label | How |
| --- | --- | --- |
| Describe the tool and generate its code | Portal | Agent Canvas > Create > Tool > Python tool. |
| Test with real inputs | Portal | The Python tool dialog's Test playground tab. |
| Create the tool | CLI | `az sre tool create`, below, with your code in `functionCode`. |
| Ask the agent to use the tool | Portal | New chat. |
| Edit or delete the tool | CLI | `az sre tool create ... --overwrite true`, or `az sre tool delete -g "$RG" --agent-name "$AGENT" --name sla-calculator --yes` |

```bash
cat > sla-calculator.json <<'JSON'
{
  "type": "PythonFunctionTool",
  "description": "Calculate SLA compliance from uptime and downtime minutes.",
  "functionCode": "def main(total_uptime_minutes: int, total_downtime_minutes: int, target_sla_percent: float = 99.9) -> dict:\n    total = total_uptime_minutes + total_downtime_minutes\n    sla = round(total_uptime_minutes / total * 100, 4) if total else 0.0\n    return {\"sla_percent\": sla, \"target_sla_percent\": target_sla_percent, \"meets_target\": sla >= target_sla_percent}\n"
}
JSON

az sre tool create -g "$RG" --agent-name "$AGENT" \
  --name sla-calculator --value "@sla-calculator.json"
```

### Install a plugin from a marketplace

Learn: [Install a Marketplace plugin](https://learn.microsoft.com/azure/sre-agent/install-plugin-from-marketplace).
**Summary:** CLI, then portal. Connect the marketplace from the CLI, then install in the
portal.

| Step | Label | How |
| --- | --- | --- |
| Add the marketplace | CLI | `az sre plugin marketplace create`, below. |
| Preview a plugin | Portal | Plugins (`/views/extensions/plugins`), select the plugin. |
| Install the plugin | Portal | Plugins > Install. `az sre plugin install create` saves only the installation record; it doesn't import the plugin's skills the way the portal does. |
| Check the imported skill | Portal | Skill builder (`/views/extensions/skillBuilder`). |
| Use the REST API instead | CLI | The tutorial's `curl` commands. |

```bash
az sre plugin marketplace create -g "$RG" --agent-name "$AGENT" \
  --name sre-agent-plugins \
  --value '{"sourceType": "github", "sourceUrl": "Azure/sre-agent-plugins"}'
```

### Install a plugin from a URL

Learn: [Install a plugin from URL](https://learn.microsoft.com/azure/sre-agent/install-plugin-from-url).
**Summary:** Portal, or the tutorial's REST call.

| Step | Label | How |
| --- | --- | --- |
| Install a plugin from a GitHub repository URL | Portal | Plugins (`/views/extensions/plugins`) > Install GitHub plugin. `az sre` has no install-from-URL command. |
| Check the imported skill | Portal | Skill builder (`/views/extensions/skillBuilder`). |
| Use the REST API instead | CLI | The tutorial's `curl` call to `/api/v2/plugins/install-direct`. |

### Use code interpreter

Learn: [Use code interpreter](https://learn.microsoft.com/azure/sre-agent/use-code-interpreter).
**Summary:** Portal.

| Step | Label | How |
| --- | --- | --- |
| Turn on Early access to features | Portal | Settings > General (`/views/settings/general`). |
| Ask for computation, download files and create charts and PDF reports | Portal | New chat. |

### Create a subagent

Learn: [Create a subagent](https://learn.microsoft.com/azure/sre-agent/create-subagent).
**Summary:** CLI to create and edit the subagent. AI help, most hooks and testing are in the
portal.

| Step | Label | How |
| --- | --- | --- |
| Create a custom agent with a name and instructions | CLI | `az sre subagent create`, below. Instructions must be at least 50 characters. |
| Refine with AI and View AI suggestions | Portal | Agent Canvas (`/views/workflows/subAgentBuilder`) > Create > Custom Agent. |
| Choose skills and tools | CLI | `allowedSkills`, `tools` and `mcpTools` in `--value`. |
| Add a hook that runs a script before every tool call | CLI | `--pre-tool-use-script-file <script>` |
| Add other hooks | Portal | Agent Canvas, the subagent > Manage Hooks. |
| Test the subagent | Portal | The dialog's Test live agent panel, or Agent Canvas > Test playground. |
| Edit the subagent | CLI | Run `az sre subagent create` again with `--overwrite true`. |
| Edit with YAML | Portal | The dialog's YAML tab. |

```bash
cat > health-check-reporter.json <<'JSON'
{
  "instructions": "You're a health check reporter. Check Azure resource health for container apps in the production resource group. Summarize healthy, warning, and critical counts.",
  "handoffDescription": "Use for health checks of the production container apps."
}
JSON

az sre subagent create -g "$RG" --agent-name "$AGENT" \
  --name health-check-reporter --value "@health-check-reporter.json"
```

### Create a skill

Learn: [Create a skill](https://learn.microsoft.com/azure/sre-agent/create-skill).
**Summary:** CLI for the skill and its tools. Supporting files and testing are in the portal.

| Step | Label | How |
| --- | --- | --- |
| Create the skill: name, description and SKILL.md instructions | CLI | `az sre skill create`, below, with the tutorial's SKILL.md. |
| Choose tools | CLI | `--tools`, a space-separated list of tool names. |
| Add supporting files | Portal | Agent Canvas, the skill > Files. `az sre skill create` uploads only SKILL.md. |
| Test the skill | Portal | New chat, or Agent Canvas > Test playground. |
| Edit the skill | CLI | Run `az sre skill create` again with `--overwrite true`. |

```bash
az sre skill create -g "$RG" --agent-name "$AGENT" \
  --name high-cpu-troubleshooting --file-path SKILL.md --tools kusto_query
```

### Use DocsGuide

Learn: [Use DocsGuide](https://learn.microsoft.com/azure/sre-agent/use-docsguide).
**Summary:** Portal.

| Step | Label | How |
| --- | --- | --- |
| Ask concept, setup, feature and "Can I" questions | Portal | New chat (`/views/thread/new`). |

## Tutorials: Knowledge and data sources

### Set up GitHub connector

Learn: [Set up GitHub connector (OAuth/PAT)](https://learn.microsoft.com/azure/sre-agent/setup-github-connector).
**Summary:** Portal. This connector gives the agent GitHub issue and pull request tools; for
code, see [Connect a source code service](#connect-a-source-code-service).

| Step | Label | How |
| --- | --- | --- |
| Add the GitHub OAuth connector, then sign in or paste a PAT | Portal | Connectors (`/views/extensions/connectors`) > Add connector > GitHub OAuth connector. |
| Create a PAT, if you use one | External | GitHub: Settings > Developer settings. |
| Ask about recent issues | Portal | New chat. |

### Set up GitHub BYO App

Learn: [Set up GitHub BYO App](https://learn.microsoft.com/azure/sre-agent/setup-github-byo-app).
**Summary:** External and CLI to prepare the app and its key, then portal to connect.

| Step | Label | How |
| --- | --- | --- |
| Create and install a GitHub App, then generate a private key | External | GitHub: Settings > Developer settings > GitHub Apps. |
| Store the private key in Key Vault as a secret | CLI | `az keyvault secret set --vault-name <vault> --name sre-agent-github-app-key --file <private-key>.pem` |
| Give the agent's managed identity Key Vault Secrets User on the vault | CLI | `az role assignment create --role "Key Vault Secrets User" --assignee-object-id <principal-id> --assignee-principal-type ServicePrincipal --scope <key-vault-resource-id>` |
| Connect with Bring your own GitHub App | Portal | Code access (`/views/context/codeAccess`) > Add repository > GitHub. `az sre repo connect` doesn't support GitHub Apps. |
| Add repositories and ask about them | Portal | Code access, then New chat. |

Get the identity's principal ID with
`az sre identity show -g "$RG" --agent-name "$AGENT" --query principalId -o tsv` for the
system-assigned identity.

### Connect GitHub Enterprise Cloud

Learn: [Connect GitHub Enterprise Cloud](https://learn.microsoft.com/azure/sre-agent/connect-github-enterprise-cloud).
**Summary:** External and CLI to prepare the app and its key, then portal to connect.

| Step | Label | How |
| --- | --- | --- |
| Create and install a GitHub App on your `ghe.com` host, then generate a private key | External | GitHub Enterprise Cloud: Settings > Developer settings > GitHub Apps. |
| Import the private key into Key Vault as an RSA key with the Sign operation | CLI | Convert it to PKCS#8 with `openssl pkcs8 -topk8 -nocrypt -in <private-key>.pem -out key-pkcs8.pem`, then `az keyvault key import --vault-name <vault> --name sre-agent-github-app-key --pem-file key-pkcs8.pem --ops sign`. Delete both PEM files afterward. |
| Give the agent's identity Key Vault Crypto User on the key | CLI | `az role assignment create --role "Key Vault Crypto User" --assignee-object-id <principal-id> --assignee-principal-type ServicePrincipal --scope <key-resource-id>` |
| Connect with Use your GitHub App, using the key's `/keys/` URI | Portal | Code access (`/views/context/codeAccess`) > Add repository > GitHub. |
| Add repositories and ask about them | Portal | Code access, then New chat. |

The GitHub BYO App tutorial stores the key as a secret, while this one and
[Connect a source code service](#connect-a-source-code-service) require an RSA key. Follow the
tutorial for your host.

### Set up Kusto connector

Learn: [Set up Kusto connector](https://learn.microsoft.com/azure/sre-agent/kusto-connector).
**Summary:** CLI to add the connector. The database permission is granted in Azure Data
Explorer, and the connection test is in the portal.

| Step | Label | How |
| --- | --- | --- |
| Give the agent's managed identity viewer access to the database | External | In Azure Data Explorer, run `.add database <database> viewers ('aadapp=<client-id>')`. |
| Add the Azure Data Explorer connector with a cluster group | CLI | Commands below. Each cluster group becomes its own `Kusto` connector; add one connector per cluster. |
| Make the connector's query tools visible to the main agent | CLI | `--tool-access true` |
| Use a different managed identity for a cluster group | CLI | `--identity <identity-resource-id>` on that group's connector. |
| Test the connection | Portal | Connectors (`/views/extensions/connectors`), the connector. |
| Ask the agent to list the tables | Portal | New chat. |

```bash
az sre connector create -g "$RG" --agent-name "$AGENT" \
  --name azure-data-explorer --data-connector-type "Azure Data Explorer" --tool-access true

az sre connector create -g "$RG" --agent-name "$AGENT" \
  --name production --data-connector-type Kusto \
  --data-source "https://<cluster>.<region>.kusto.windows.net/<database>"
```

### Set up Azure DevOps connector

Learn: [Set up Azure DevOps connector](https://learn.microsoft.com/azure/sre-agent/azure-devops-connector).
**Summary:** Portal. For Azure DevOps code, see
[Connect a source code service](#connect-a-source-code-service).

| Step | Label | How |
| --- | --- | --- |
| Add the Azure DevOps OAuth connector with your account or a managed identity | Portal | Connectors (`/views/extensions/connectors`) > Add connector > Azure DevOps OAuth connector. |
| Use the Documentation connector with a PAT instead | Portal | Connectors > Add connector > Documentation connector. |
| Ask about repositories or commits | Portal | New chat. |
| Edit or delete the connector | Portal | Connectors, the connector's **...** menu. |

### Set up Outlook connector

Learn: [Set up Outlook connector](https://learn.microsoft.com/azure/sre-agent/outlook-connector).
**Summary:** Portal. The connector needs an Outlook sign-in.

| Step | Label | How |
| --- | --- | --- |
| Add the Office 365 Outlook connector and sign in | Portal | Connectors (`/views/extensions/connectors`) > Add connector > Office 365 Outlook. |
| Choose the managed identity and add the connector | Portal | Same wizard. |
| Send a test email | Portal | New chat. |
| Edit or delete the connector | Portal | Connectors, the connector's **...** menu. |

`az sre connector create` doesn't create Outlook connectors and points to the portal. The
service creates them as managed connectors, and it rejects a create that doesn't choose a
sign-in method.

### Set up MCP connector

Learn: [Set up MCP connector](https://learn.microsoft.com/azure/sre-agent/mcp-connector).
**Summary:** CLI for HTTP MCP servers. OAuth consent, the SSE connection type and choosing
tools for the main agent are in the portal.

| Step | Label | How |
| --- | --- | --- |
| Add an MCP server with no authentication, an API key or bearer token, or a managed identity | CLI | `az sre connector create -g "$RG" --agent-name "$AGENT" --name my-mcp --data-connector-type Mcp --mcp-endpoint "https://<server>/mcp"`, plus `--bearer-token "@token.txt"` (a file that holds the token) or `--managed-identity-auth true` if needed. |
| Add an MCP server that signs in with OAuth | CLI, then portal | Add `--oauth-dcr true`, then finish the consent in the portal at the link the command prints. Check the sign-in there too: `az sre connector show` reports `consentStatus` only for EntraOAuth connectors. |
| Connect the GitHub MCP server | CLI | `az sre connector create -g "$RG" --agent-name "$AGENT" --name github --data-connector-type Mcp --github true` |
| Use the SSE connection type | Portal | Connectors > Add connector > MCP server. The CLI's `--mcp-endpoint` uses the HTTP transport. |
| Select the connector's tools for the main agent | Portal | Connectors, the connector > Edit > MCP Tools. For a custom agent, list the tools in `mcpTools` with `az sre subagent create`. |
| Test in chat | Portal | New chat. |

### Set up SRE Agent MCP server

Learn: [Set up SRE Agent MCP server](https://learn.microsoft.com/azure/sre-agent/setup-mcp-server).
**Summary:** CLI and your MCP client. The tutorial already uses the terminal.

| Step | Label | How |
| --- | --- | --- |
| Sign in to Azure | CLI | `az login`, and `az account set --subscription "$SUBSCRIPTION_ID"` |
| Give yourself Reader and SRE Agent Administrator on the agent | CLI | `az sre access grant -g "$RG" --agent-name "$AGENT" --role admin --assignee-me` for SRE Agent Administrator, and the tutorial's `az role assignment create --role "Reader"` command for Reader. |
| Register the Azure MCP server with your client | External | Your MCP client's configuration, for example VS Code or Copilot CLI. |
| Verify the connection and run investigations | External | Your MCP client. |

### Set up a managed connector

Learn: [Set up a managed connector](https://learn.microsoft.com/azure/sre-agent/setup-managed-connector).
**Summary:** Portal, or the tutorial's REST calls with a portal sign-in for OAuth connectors.

| Step | Label | How |
| --- | --- | --- |
| Pick a connector and sign in | Portal | Connectors (`/views/extensions/connectors`) > Add connector. |
| Set up tools: choose operations, lock parameters, set Allow or Ask | Portal | Same wizard. |
| Review and create | Portal | Same wizard. |
| Use the connector in chat | Portal | New chat. |
| Edit or delete the connector | Portal | Connectors. |
| Use the REST API instead | CLI, then portal | The tutorial's `curl` calls, with a token from `az account get-access-token --resource https://azuresre.dev`. OAuth connectors still need the portal to sign in. |

### Connect a source code service

Learn: [Connect a source code service](https://learn.microsoft.com/azure/sre-agent/connect-code-service).
**Summary:** CLI for GitHub and Azure DevOps with tokens or a managed identity. GitHub Apps and
GitLab are in the portal.

| Step | Label | How |
| --- | --- | --- |
| GitHub with a GitHub App, required for GitHub Enterprise Cloud | Portal | Code access (`/views/context/codeAccess`) > Add repository > GitHub. |
| GitHub with OAuth or a PAT | CLI | `az sre repo connect -g "$RG" --agent-name "$AGENT" --repo-url "https://github.com/<org>/<repo>"`. To use a PAT, set `GITHUB_TOKEN` to it first. |
| Azure DevOps with a managed identity | CLI | `az sre repo connect -g "$RG" --agent-name "$AGENT" --repo-url "https://dev.azure.com/<org>/<project>/_git/<repo>" --devops-auth-type managed-identity --devops-identity <identity-resource-id>` |
| Azure DevOps with your account or a PAT | CLI | The same command without the managed identity flags. The CLI creates a PAT from your sign-in. |
| GitLab with a PAT | Portal | Code access > Add repository > GitLab. `az sre repo connect` supports GitHub and Azure DevOps only. |
| Add more repositories and set display names | CLI | One `az sre repo connect` per repository, with `--display-name`. |
| Use the Remote option for Azure DevOps search without cloning | Portal | Code access, while adding the repository. |
| Ask a question about the repositories | Portal | New chat. |

### Connect a notification service

Learn: [Connect a notification service](https://learn.microsoft.com/azure/sre-agent/connect-notification-service).
**Summary:** Portal. Outlook, Teams, Gmail and Viva Engage connect through managed connectors,
which `az sre` doesn't create.

| Step | Label | How |
| --- | --- | --- |
| Add the connector from the Notification tab | Portal | Connectors (`/views/extensions/connectors`) > Add connector > Notification. |
| Sign in | Portal | Same wizard. |
| Enable the send or post operation, set it to Ask and lock the destination | Portal | Same wizard. |
| Ask the agent to send a message, then approve it | Portal | New chat. |

### Connect a telemetry source

Learn: [Connect a telemetry source](https://learn.microsoft.com/azure/sre-agent/connect-telemetry-source).
**Summary:** CLI for Azure Data Explorer, portal for everything else.

| Step | Label | How |
| --- | --- | --- |
| Azure Data Explorer through Azure MCP | CLI | See [Set up Kusto connector](#set-up-kusto-connector). |
| Log Analytics Workspace or Application Insights | Portal | Connectors (`/views/extensions/connectors`) > Add connector > Telemetry. |
| Datadog, Elasticsearch, Dynatrace, New Relic, Splunk or Hawkeye | Portal | Same tab. |
| Set up query tools: Allow for reads, Ask for changes | Portal | Same wizard. |
| Ask a question the source can answer | Portal | New chat. |

### Connect Log Analytics and Application Insights

Learn: [Set up Log Analytics connector](https://learn.microsoft.com/azure/sre-agent/setup-log-analytics-connector).
**Summary:** Portal. When you save, the portal assigns Log Analytics Reader and Monitoring Reader
on the workspace's resource group and adds the group to the agent's managed resources.

| Step | Label | How |
| --- | --- | --- |
| Add the Log Analytics Workspace or Application Insights connector | Portal | Connectors (`/views/extensions/connectors`) > Add connector. |
| Select the workspace or resource, or enter its resource ID | Portal | Same wizard. |
| Find a workspace's Customer ID for manual entry | CLI | `az monitor log-analytics workspace show -g <workspace-rg> --workspace-name <workspace> --query customerId -o tsv` |
| Add the connector and check it's Connected | Portal | Same wizard, then Connectors. |
| Ask what tables the workspace has | Portal | New chat. |

### Create a Kusto tool

Learn: [Create a Kusto tool](https://learn.microsoft.com/azure/sre-agent/create-kusto-tool).
**Summary:** CLI to create the tool and add it to a custom agent. Testing is in the portal.

| Step | Label | How |
| --- | --- | --- |
| Give the agent's managed identity AllDatabasesViewer on the cluster | External | Azure Data Explorer cluster permissions. |
| Create the Kusto tool: name, description, connector, database, query and parameter | CLI | `az sre tool create`, below. `##timeRange##` in the query becomes the `timeRange` parameter. |
| Test the query | Portal | Agent Canvas (`/views/workflows/subAgentBuilder`) > Test playground. The CLI saves the tool without a test run. |
| Add the tool to a custom agent | CLI | Run `az sre subagent create` again with `--overwrite true` and the tool's name in `tools`. |
| Check the tool in the playground | Portal | Agent Canvas > Test playground. |
| Edit or delete the tool | CLI | `az sre tool create ... --overwrite true`, or `az sre tool delete -g "$RG" --agent-name "$AGENT" --name query-app-logs --yes` |

```bash
cat > query-app-logs.json <<'JSON'
{
  "type": "KustoTool",
  "connector": "production",
  "toolMode": "Auto",
  "description": "Query AppLogs table for errors in the specified time range",
  "database": "<database>",
  "query": "AppLogs | where Timestamp > ago(##timeRange##) | where Level == \"Error\" | order by Timestamp desc | take 10",
  "parameters": [
    {"name": "timeRange", "type": "string", "description": "How far back to look (for example, 1h, 24h, 7d)", "required": true}
  ]
}
JSON

az sre tool create -g "$RG" --agent-name "$AGENT" \
  --name query-app-logs --value "@query-app-logs.json"
```

### Upload knowledge documents

Learn: [Upload knowledge documents](https://learn.microsoft.com/azure/sre-agent/tutorial-upload-knowledge-document).
**Summary:** CLI for single files. Runbooks written by the agent, folders and indexing status
are in the portal.

| Step | Label | How |
| --- | --- | --- |
| Ask the agent to turn an investigation into a runbook | Portal | The investigation's chat thread. |
| Check that the runbook is Indexed | Portal | Knowledge sources (`/views/context/knowledgeSources`). `az sre knowledge list -g "$RG" --agent-name "$AGENT"` lists it. |
| Upload a file | CLI | `az sre knowledge create -g "$RG" --agent-name "$AGENT" --name high-memory-runbook --type file --file-path ./high-memory-runbook.md` |
| Upload a folder | Portal | Knowledge sources > Add file. |
| Ask a question the runbook answers | Portal | New chat. |
| Replace a document | CLI | Run `az sre knowledge create` again with `--overwrite true`. |
| Delete a document | CLI | `az sre knowledge delete -g "$RG" --agent-name "$AGENT" --name high-memory-runbook --yes` |

### Connect Azure DevOps Wiki

Learn: [Connect Azure DevOps Wiki](https://learn.microsoft.com/azure/sre-agent/connect-devops-wiki).
**Summary:** Portal, after preparing access in Azure DevOps.

| Step | Label | How |
| --- | --- | --- |
| Copy the wiki URL | External | Azure DevOps: the project's Wiki. |
| Add the agent's managed identity to the organization, or create a PAT with Code (Read) | External | Azure DevOps: Organization settings > Users, or your PAT settings. |
| Add the Documentation connector with the wiki URL and authentication | Portal | Connectors (`/views/extensions/connectors`) > Add connector > Documentation connector. |
| Ask a question the wiki answers | Portal | New chat. |

### Manage global tools

Learn: [Manage global tools](https://learn.microsoft.com/azure/sre-agent/manage-global-tools).
**Summary:** Portal.

| Step | Label | How |
| --- | --- | --- |
| Turn on workspace tools for agents created before March 10, 2026 | Portal | Capabilities > Experimental settings. |
| Browse, search and turn built-in tools on or off, or reset them | Portal | Tools (`/views/extensions/tools`). `az sre agent settings update` accepts `toolStatuses`, but the change doesn't read back; see the [operations guide](operations.md). |
| See MCP and custom tools | Portal | Tools. `az sre tool list -g "$RG" --agent-name "$AGENT"` lists the custom tools. |

### Connect an Azure DevOps repository with managed identity

Learn: [Connect ADO repo with managed identity](https://learn.microsoft.com/azure/sre-agent/connect-ado-repo-managed-identity).
**Summary:** Azure DevOps for access, then CLI.

| Step | Label | How |
| --- | --- | --- |
| Add the managed identity to the Azure DevOps organization with Code (Read) access | External | Azure DevOps: Organization settings > Users. |
| Connect with Managed Identity and add the repositories | CLI | `az sre repo connect -g "$RG" --agent-name "$AGENT" --repo-url "https://dev.azure.com/<org>/<project>/_git/<repo>" --devops-auth-type managed-identity --devops-identity <identity-resource-id>`, once per repository. |
| Use a federated identity credential for an organization in another tenant | CLI | Add `--devops-federated-client-id <client-id> --devops-federated-tenant-id <tenant-id>`. |
| Check the repositories | Portal | Code access (`/views/context/codeAccess`). |

### Cross-account Azure DevOps access

Learn: [Cross-account ADO access](https://learn.microsoft.com/azure/sre-agent/cross-account-azdo-oauth-authorization).
**Summary:** Portal. The browser sign-in uses an account from the other tenant.

| Step | Label | How |
| --- | --- | --- |
| Connect with Your account, sign in with the other tenant's account and authorize | Portal | Code access (`/views/context/codeAccess`) > Add repository > Azure DevOps. |
| Select repositories and save | Portal | Same dialog. |
| Ask about the repositories | Portal | New chat. |

### Add a web page knowledge source

Learn: [Add a web page knowledge source](https://learn.microsoft.com/azure/sre-agent/add-web-page).
**Summary:** CLI. The optional description and indexing status are in the portal.

| Step | Label | How |
| --- | --- | --- |
| Add the web page with its URL and a name | CLI | `az sre knowledge create -g "$RG" --agent-name "$AGENT" --name azure-monitor-overview --type webpage --url "https://learn.microsoft.com/azure/azure-monitor/overview"` |
| Add a description | Portal | Knowledge sources (`/views/context/knowledgeSources`) > Add web page. The CLI has no description option. |
| Check the knowledge source | CLI | `az sre knowledge show -g "$RG" --agent-name "$AGENT" --name azure-monitor-overview`. The indexing status is on the Knowledge sources page. |
| Ask a question the page answers | Portal | New chat. |
| Refresh the page's content | CLI | Run `az sre knowledge create` again with `--overwrite true`. |
