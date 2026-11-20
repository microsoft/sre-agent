# `az sre` CLI ergonomics reference

Reference for `sre` version 1.0.0b2 (preview), generated from the extension's
command and help metadata.

Public surface: **24 groups** and **84 commands**.

## Important caveats

- Some setup steps need the SRE Agent portal. The [portal and CLI handoff guide](portal-cli-handoff.md) goes through each Microsoft Learn tutorial step by step and gives the `az sre` command or the portal page for each one.
- This CLI uses both the control plane (`Microsoft.App/agents` ARM resource) and the agent's own data plane (`*.azuresre.ai`). The route depends on the operation and tenant. See the [operations guide](operations.md).
- This reference includes the complete command surface, including Microsoft-internal options where documented. Interactive help can hide those options for other tenants; generation does not depend on your signed-in account.
- `network update` is hand-written against the real `2026-11-01-preview` api-version; there is no public Swagger for it yet. See the [networking guide](networking.md).
- `--value` JSON documents (e.g. `tool create`, `skill create`, `agent settings update`) are validated and sent in the envelope required by the selected API. Each extension type has its own dedicated front-door noun (`tool`, `skill`, `hook`, `instructions`, `plugin marketplace`/`plugin install`, `repo connect`, `agent settings`); there is no generic `extension` escape hatch anymore. See the [operations guide](operations.md).
- `connector list-secret` is the only command that can return connector secret material in plain text; everything else (`connector show`, `connector list`, `connector create`/`update` responses) leaves secret fields out.

## Global options

These Azure CLI global options apply to every command and are not repeated in each syntax line.

| Option | Description |
| --- | --- |
| `--debug` | Increase logging verbosity to show all debug logs. |
| `--help, -h` | Show this help message and exit. |
| `--only-show-errors` | Only show errors, suppressing warnings. |
| `--output, -o` | Output format: json, jsonc, none, table, tsv, yaml, or yamlc. |
| `--query` | JMESPath query string. |
| `--subscription` | Subscription name or ID; otherwise use the active subscription. |
| `--verbose` | Increase logging verbosity. |

## `az sre`

Manage Azure SRE Agent resources.

In PowerShell, pass JSON with --value @file.json instead of inline.

| Subgroup | Summary |
| --- | --- |
| `access` | Control who can manage or use an SRE Agent. |
| `agent` | Manage the core lifecycle of an SRE Agent resource. |
| `automation` | Manage agent automations. |
| `connector` | Connect an SRE Agent to an external data source it can query or act on. |
| `endpoint` | Resolve the URL used to actually talk to an SRE Agent's data plane. |
| `hook` | Manage lifecycle hooks that run a prompt or script at a specific agent event. |
| `identity` | Manage the agent's own managed identity. |
| `instructions` | Manage named, reusable prompt snippets ('commonPrompts'). |
| `knowledge` | Add files or web pages the agent can read and reason over. |
| `managed-resource` | Let the agent monitor resources outside its resource group. |
| `network` | Control an SRE Agent's sandbox networking (preview). |
| `plugin` | Manage community plugins that add skills, tools, and integrations. |
| `repo` | Connect a code repository so the agent can read source during investigations. |
| `response-plan` | Route incidents to a subagent (portal: Triggers & response plans). |
| `skill` | Manage custom skills, which are specialized capabilities the agent can use. |
| `subagent` | Manage named sub-agents the meta-agent can hand off work to. |
| `tool` | Manage custom tools the agent can call. |
| `usage` | Read an SRE Agent's usage and billing stats. |

| Verb | Exact syntax |
| --- | --- |
| `version` | `az sre version` |

### `az sre version`

Show the installed extension version and the Azure API versions it uses.

Reads installed package metadata only, so it works without signing in. Include the output when you report a bug.

**Syntax**

`az sre version`

**Examples**

- Show version information

  ```bash
  az sre version
  ```
- Print only the extension version

  ```bash
  az sre version --query extensionVersion -o tsv
  ```

## `az sre access`

Control who can manage or use an SRE Agent.

This is the mirror image of 'sre managed-resource': that group grants the agent's own identity access to things outside itself, while this group grants other people/principals access to the agent itself.

| Verb | Exact syntax |
| --- | --- |
| `grant` | `az sre access grant --name <value> --resource-group <value> --role {admin,user,author,reader} [--assignee <value>] [--assignee-me {false,true}]` |
| `list` | `az sre access list --name <value> --resource-group <value> [--show-names {false,true}]` |
| `revoke` | `az sre access revoke --name <value> --resource-group <value> --role {admin,user,author,reader} [--assignee <value>] [--assignee-me {false,true}]` |

### `az sre access grant`

Grant an agent role to a user, group or principal.

**Syntax**

`az sre access grant --name <value> --resource-group <value> --role {admin,user,author,reader} [--assignee <value>] [--assignee-me {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent to grant access on. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--role` | String | Yes |  | `admin`, `user`, `author`, `reader` | Built-in role to grant: 'admin', 'user', 'author', or 'reader'. |
| `--assignee` | String | No |  |  | User, group, or service principal object ID/UPN to grant the role for. Required unless --assignee-me is passed instead. |
| `--assignee-me` | Boolean | No |  | `false`, `true` | Use the signed-in account as the assignee. Reads your object ID from your Azure access token, without Microsoft Graph. Alternative to --assignee. |

**Examples**

- Grant yourself admin access to an agent

  ```bash
  az sre access grant --name myagent --resource-group myrg --role admin --assignee-me
  ```
- Grant a user read-only access

  ```bash
  az sre access grant --name myagent --resource-group myrg --role reader --assignee someone@contoso.com
  ```

### `az sre access list`

List who has access to an SRE Agent.

Shows every role assignment on the agent itself, plus SRE Agent roles (Administrator, Standard User, Author, Reader) inherited from its resource group, subscription, or management group. Each item has "inherited": true when it was granted above the agent. Lists object IDs; use --show-names to add display names from Microsoft Graph.

**Syntax**

`az sre access list --name <value> --resource-group <value> [--show-names {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent to list access on. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--show-names` | Boolean | No | false | `false`, `true` | Add principal display names from Microsoft Graph. Some organizations' policies block Graph for Azure CLI on macOS. |

**Examples**

- List everyone with access to an agent

  ```bash
  az sre access list --name myagent --resource-group myrg
  ```
- Include display names

  ```bash
  az sre access list --name myagent --resource-group myrg --show-names
  ```

### `az sre access revoke`

Revoke an agent role from a user, group or principal.

**Syntax**

`az sre access revoke --name <value> --resource-group <value> --role {admin,user,author,reader} [--assignee <value>] [--assignee-me {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent to revoke access on. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--role` | String | Yes |  | `admin`, `user`, `author`, `reader` | Built-in role to revoke: 'admin', 'user', 'author', or 'reader'. |
| `--assignee` | String | No |  |  | User, group, or service principal object ID/UPN to revoke the role for. Required unless --assignee-me is passed instead. |
| `--assignee-me` | Boolean | No |  | `false`, `true` | Use the signed-in account as the assignee. Reads your object ID from your Azure access token, without Microsoft Graph. Alternative to --assignee. |

**Examples**

- Revoke a user's access to an agent

  ```bash
  az sre access revoke --name myagent --resource-group myrg --role user --assignee someone@contoso.com
  ```

## `az sre agent`

Manage the core lifecycle of an SRE Agent resource.

Create, show, list, update, delete, start, and stop an agent.

| Subgroup | Summary |
| --- | --- |
| `settings` | Manage an SRE Agent's global settings (preview). |

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre agent create [--no-wait] --name <value> --resource-group <value> [--system-assigned <value>] [--user-assigned <json-or-@file>] [--action-configuration <json-or-@file>] [--agent-identity <json-or-@file>] [--default-model <json-or-@file>] [--incident-management-configuration <json-or-@file>] [--knowledge-graph-configuration <json-or-@file>] [--log-configuration <json-or-@file>] [--upgrade-channel {Preview,Stable}] --location <value> [--tags <json-or-@file>] [--grant-access-to-me {admin,user,author,reader}] [--experimental-settings <json-or-@file>] [--monthly-unit-limit <integer>]` |
| `delete` | `az sre agent delete [--no-wait] --name <value> --resource-group <value> [--yes]` |
| `list` | `az sre agent list [--next-token <value>] [--max-items <value>] [--resource-group <value>]` |
| `list-models` | `az sre agent list-models [--next-token <value>] [--max-items <value>] --location <value>` |
| `show` | `az sre agent show --name <value> --resource-group <value>` |
| `start` | `az sre agent start [--no-wait] --name <value> --resource-group <value>` |
| `stop` | `az sre agent stop [--no-wait] --name <value> --resource-group <value>` |
| `update` | `az sre agent update [--no-wait] [--add <value>] [--set <value>] [--remove <value>] [--force-string {true,t,yes,y,1,false,f,no,n,0}] --name <value> --resource-group <value> [--action-configuration <json-or-@file>] [--agent-identity <json-or-@file>] [--default-model <json-or-@file>] [--incident-management-configuration <json-or-@file>] [--knowledge-graph-configuration <json-or-@file>] [--log-configuration <json-or-@file>] [--upgrade-channel {Preview,Stable}] [--tags <json-or-@file>] [--experimental-settings <json-or-@file>] [--monthly-unit-limit <integer>]` |
| `wait` | `az sre agent wait --name <value> --resource-group <value>` |

### `az sre agent create`

Create an SRE Agent.

**Syntax**

`az sre agent create [--no-wait] --name <value> --resource-group <value> [--system-assigned <value>] [--user-assigned <json-or-@file>] [--action-configuration <json-or-@file>] [--agent-identity <json-or-@file>] [--default-model <json-or-@file>] [--incident-management-configuration <json-or-@file>] [--knowledge-graph-configuration <json-or-@file>] [--log-configuration <json-or-@file>] [--upgrade-channel {Preview,Stable}] --location <value> [--tags <json-or-@file>] [--grant-access-to-me {admin,user,author,reader}] [--experimental-settings <json-or-@file>] [--monthly-unit-limit <integer>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--system-assigned`, `--mi-system-assigned` | String | No |  |  | Enable the system-assigned identity. Default: a user-assigned identity is created and both are enabled. |
| `--user-assigned`, `--mi-user-assigned` | List | No |  |  | User-assigned identities to attach. |
| `--action-configuration` | Object | No |  |  | What the agent may do and how. Without identity, actions run as the agent's user-assigned identity (the one created for it, or the one given with --mi-user-assigned), or as "system" when it has only a system-assigned identity. |
| `--agent-identity` | Object | No |  |  | Agent identity configuration for accessing resources |
| `--default-model` | Object | No |  |  | Default AI model configuration for the agent |
| `--incident-management-configuration`, `--incident-config` | Object | No |  |  | Incident management configurations |
| `--knowledge-graph-configuration`, `--knowledge-graph` | Object | No |  |  | Knowledge graph configuration for agent |
| `--log-configuration` | Object | No |  |  | Application Insights link for traces. Without it, a warning is shown and trace view is unavailable. |
| `--upgrade-channel` | String | No |  | `Preview`, `Stable` | The upgrade channel of the agent |
| `--location`, `-l` | String | Yes |  |  | The geo-location where the resource lives |
| `--tags` | Dictionary | No |  |  | Resource tags. |
| `--grant-access-to-me` | String | No |  | `admin`, `user`, `author`, `reader` | Grant yourself a built-in role after creation. Cannot be used with --no-wait. |
| `--experimental-settings` | Dictionary | No |  |  | Preview feature flags as JSON or @file, e.g. '{"EnableWorkspaceTools": true}'. Merged into the agent's existing flags. |
| `--monthly-unit-limit` | Integer | No |  |  | Monthly agent unit (AAU) cap for this agent. 0 restores the service default. The service enforces a minimum (currently 500). |

**Examples**

- Create an agent with an Anthropic default model

  ```bash
  az sre agent create --name myagent --resource-group myrg \
  --location eastus2 --default-model "{provider:anthropic,name:automatic}"
  ```
- Create an agent with preview feature flags turned on

  ```bash
  az sre agent create --name myagent --resource-group myrg --location eastus2 \
  --experimental-settings "{\"EnableWorkspaceTools\": true}"
  ```

### `az sre agent delete`

Delete an SRE Agent.

**Syntax**

`az sre agent delete [--no-wait] --name <value> --resource-group <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete an agent after confirming interactively

  ```bash
  az sre agent delete --name myagent --resource-group myrg
  ```
- Delete an agent without an interactive confirmation prompt

  ```bash
  az sre agent delete --name myagent --resource-group myrg --yes
  ```

### `az sre agent list`

List SRE Agents in a subscription or resource group.

**Syntax**

`az sre agent list [--next-token <value>] [--max-items <value>] [--resource-group <value>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--next-token` | String | No |  |  | Token to specify where to start paginating. This is the token value from a previously truncated response. |
| `--max-items` | String | No |  |  | Total number of items to return in the command's output. If the total number of items available is more than the value specified, a token is provided in the command's output. To resume pagination, provide the token value in `--next-token` argument of a subsequent command. |
| `--resource-group`, `-g` | String | No |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List all agents in a resource group

  ```bash
  az sre agent list --resource-group myrg
  ```
- List all agents in the current subscription

  ```bash
  az sre agent list
  ```

### `az sre agent list-models`

List the models supported for new agents in a region.

Use this before 'sre agent create' to confirm --default-model is supported in the region you're deploying to.

**Syntax**

`az sre agent list-models [--next-token <value>] [--max-items <value>] --location <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--next-token` | String | No |  |  | Token to specify where to start paginating. This is the token value from a previously truncated response. |
| `--max-items` | String | No |  |  | Total number of items to return in the command's output. If the total number of items available is more than the value specified, a token is provided in the command's output. To resume pagination, provide the token value in `--next-token` argument of a subsequent command. |
| `--location`, `-l` | String | Yes |  |  | Location. Values from: `az account list-locations`. You can configure the default location using `az configure --defaults location=<location>`. |

**Examples**

- See which models are available in East US 2

  ```bash
  az sre agent list-models --location eastus2
  ```

### `az sre agent show`

Show the details of an SRE Agent.

**Syntax**

`az sre agent show --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Show one agent's details

  ```bash
  az sre agent show --name myagent --resource-group myrg
  ```

### `az sre agent start`

Start a stopped SRE Agent.

The command waits until the agent's own API answers, which can take a minute or two after the agent is running. Until then, commands that use that API can report items as not found. --no-wait returns without waiting.

**Syntax**

`az sre agent start [--no-wait] --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Start a stopped agent

  ```bash
  az sre agent start --name myagent --resource-group myrg
  ```

### `az sre agent stop`

Stop a running SRE Agent.

**Syntax**

`az sre agent stop [--no-wait] --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Stop a running agent

  ```bash
  az sre agent stop --name myagent --resource-group myrg
  ```

### `az sre agent update`

Update an SRE Agent.

PagerDuty and ServiceNow set the same agent property as the portal's Incidents > Connect an incident platform workflow, not the separate Connector Gateway used by Jira, Slack and SharePoint. The portal also saves which PagerDuty services or ServiceNow assignment group to index; set that in the portal. --connection-key is the PagerDuty REST API access key; --obo-user is the identity the agent acts under when resolving or commenting on incidents. ServiceNow uses Basic Auth: set --connection-url to the instance URL and --connection-key to the credentials. The connection key is a secret. Typed on the command line, it shows up in --debug output and shell history, so put the configuration in a JSON file and pass it with @file instead, for example a pagerduty.json holding `{"type": "PagerDuty", "connectionName": "pagerduty", "connectionKey": "<api-key>", "oboUser": "oncall@contoso.com"}`. Azure Monitor must also be connected before a response plan can use it. A new agent has no incident platform set.

**Syntax**

`az sre agent update [--no-wait] [--add <value>] [--set <value>] [--remove <value>] [--force-string {true,t,yes,y,1,false,f,no,n,0}] --name <value> --resource-group <value> [--action-configuration <json-or-@file>] [--agent-identity <json-or-@file>] [--default-model <json-or-@file>] [--incident-management-configuration <json-or-@file>] [--knowledge-graph-configuration <json-or-@file>] [--log-configuration <json-or-@file>] [--upgrade-channel {Preview,Stable}] [--tags <json-or-@file>] [--experimental-settings <json-or-@file>] [--monthly-unit-limit <integer>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `--add` | String | No |  |  | Add an object to a list of objects by specifying a path and key value pairs. Example: `--add property.listProperty <key=value, string or JSON string>` |
| `--set` | String | No |  |  | Update an object by specifying a property path and value to set. Example: `--set property1.property2=<value>` |
| `--remove` | String | No |  |  | Remove a property or an element from a list. Example: `--remove property.list <indexToRemove>` OR `--remove propertyToRemove` |
| `--force-string` | String | No |  | `true`, `t`, `yes`, `y`, `1`, `false`, `f`, `no`, `n`, `0` | When using 'set' or 'add', preserve string literals instead of attempting to convert to JSON. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--action-configuration` | Object | No |  |  | Configuration for action |
| `--agent-identity` | Object | No |  |  | Agent identity configuration for accessing resources |
| `--default-model` | Object | No |  |  | Default AI model configuration for the agent |
| `--incident-management-configuration`, `--incident-config` | Object | No |  |  | Incident management configurations |
| `--knowledge-graph-configuration`, `--knowledge-graph` | Object | No |  |  | Knowledge graph configuration for agent |
| `--log-configuration` | Object | No |  |  | Log configurations |
| `--upgrade-channel` | String | No |  | `Preview`, `Stable` | The upgrade channel of the agent |
| `--tags` | Dictionary | No |  |  | Resource tags. |
| `--experimental-settings` | Dictionary | No |  |  | Preview feature flags as JSON or @file, e.g. '{"EnableWorkspaceTools": true}'. Merged into the agent's existing flags. |
| `--monthly-unit-limit` | Integer | No |  |  | Monthly agent unit (AAU) cap for this agent. 0 restores the service default. The service enforces a minimum (currently 500). |

**Examples**

- Switch an agent's default model to MicrosoftFoundry

  ```bash
  az sre agent update --name myagent --resource-group myrg \
  --default-model "{provider:MicrosoftFoundry,name:gpt-5}"
  ```
- Connect Azure Monitor as the incident platform

  ```bash
  az sre agent update --name myagent --resource-group myrg \
  --incident-management-configuration "{type:AzMonitor,connection-name:azmonitor}"
  ```
- Connect PagerDuty as the incident platform, reading the configuration and its key from a file

  ```bash
  az sre agent update --name myagent --resource-group myrg \
  --incident-management-configuration "@pagerduty.json"
  ```
- Connect ServiceNow as the incident platform with Basic Auth

  ```bash
  az sre agent update --name myagent --resource-group myrg \
  --incident-management-configuration "{type:ServiceNow,connection-name:servicenow,connection-url:'https://contoso.service-now.com',connection-key:<credentials>}"
  ```
- Turn on preview feature flags from a file

  ```bash
  az sre agent update --name myagent --resource-group myrg \
  --experimental-settings "@experimental.json"
  ```

### `az sre agent wait`

Wait for an SRE Agent to reach a desired state.

**Syntax**

`az sre agent wait --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Wait until an agent created with --no-wait finishes provisioning

  ```bash
  az sre agent wait -g myrg --agent-name myagent --created
  ```

## `az sre automation`

Manage agent automations.

Covers scheduled tasks and HTTP triggers. Response plans live under 'az sre response-plan' instead.

| Subgroup | Summary |
| --- | --- |
| `http-trigger` | Manage HTTP triggers that run the agent on a webhook call. |
| `scheduled-task` | Manage scheduled tasks that run the agent on a cron timer. |

## `az sre connector`

Connect an SRE Agent to an external data source it can query or act on.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre connector create [--no-wait] --agent-name <value> --name <value> --resource-group <value> [--data-connector-type <value>] [--data-source <value>] [--endpoint <value>] [--extended-properties <json-or-@file>] [--identity <value>] [--overwrite {false,true}] [--file-path <value>] [--mcp-endpoint <value>] [--github {false,true}] [--tool-access {false,true}] [--bearer-token <value>] [--bearer-token-file <value>] [--managed-identity-auth {false,true}] [--mi-token-scope <value>] [--oauth-dcr {false,true}] [--oauth-scopes <value>] [--oauth-client-name <value>] [--partner-type <value>]` |
| `delete` | `az sre connector delete [--no-wait] --agent-name <value> --name <value> --resource-group <value> [--yes]` |
| `list` | `az sre connector list [--next-token <value>] [--max-items <value>] --name <value> --resource-group <value>` |
| `list-secret` | `az sre connector list-secret --agent-name <value> --name <value> --resource-group <value>` |
| `show` | `az sre connector show --agent-name <value> --name <value> --resource-group <value>` |
| `update` | `az sre connector update [--no-wait] [--add <value>] [--set <value>] [--remove <value>] [--force-string {true,t,yes,y,1,false,f,no,n,0}] --agent-name <value> --name <value> --resource-group <value> [--data-connector-type <value>] [--data-source <value>] [--endpoint <value>] [--extended-properties <json-or-@file>] [--identity <value>] [--partner-type <value>] [--mcp-endpoint <value>] [--bearer-token <value>] [--bearer-token-file <value>] [--managed-identity-auth {false,true}] [--mi-token-scope <value>] [--oauth-dcr {false,true}] [--oauth-scopes <value>] [--oauth-client-name <value>] [--clear-auth {false,true}]` |
| `wait` | `az sre connector wait --agent-name <value> --name <value> --resource-group <value>` |

### `az sre connector create`

Create an Agent Connector.

**Syntax**

`az sre connector create [--no-wait] --agent-name <value> --name <value> --resource-group <value> [--data-connector-type <value>] [--data-source <value>] [--endpoint <value>] [--extended-properties <json-or-@file>] [--identity <value>] [--overwrite {false,true}] [--file-path <value>] [--mcp-endpoint <value>] [--github {false,true}] [--tool-access {false,true}] [--bearer-token <value>] [--bearer-token-file <value>] [--managed-identity-auth {false,true}] [--mi-token-scope <value>] [--oauth-dcr {false,true}] [--oauth-scopes <value>] [--oauth-client-name <value>] [--partner-type <value>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `--agent-name` | String | Yes |  |  | The name of the Agent |
| `-n`, `--name`, `--connector-name` | String | Yes |  |  | The name of the AgentConnector |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--data-connector-type` | String | No |  |  | Connector type, by portal name (case-insensitive): Azure Data Explorer, Database query connector (user), Log Analytics Workspace, Application Insights, MonitorClient, MCP server, EV2, Azure DevOps AI Search, IcM connector, DGrep, Geneva Metrics, S360 connector. For knowledge sources use 'az sre knowledge create'. Set up Outlook, Teams and other managed connectors in the portal. |
| `--data-source` | String | No |  |  | Connection string or endpoint. For Kusto, include the database: `https://cluster.kusto.windows.net/database`. On update, pass it again, or null for none. |
| `--endpoint` | String | No |  |  | Endpoint URL, used by endpoint-based connector types such as Mcp. |
| `--extended-properties` | Dictionary | No |  |  | Type-specific settings as JSON or shorthand. On update, this replaces all of them, unless an MCP flag is used; then it's merged with the settings the service returns. |
| `--identity` | String | No |  |  | 'system' for the agent's system-assigned identity, or a user-assigned identity resource ID. On create, leave it out for no identity; on update, pass it again, or null for none. |
| `--overwrite` | Boolean | No | false | `false`, `true` | Replace an existing connector with the same name instead of failing. |
| `--file-path` | String | No |  |  | Local file to ingest. For knowledge sources use 'az sre knowledge create'. |
| `--mcp-endpoint` | String | No |  |  | For Mcp: the MCP server's HTTP endpoint URL. |
| `--github` | Boolean | No |  | `false`, `true` | For Mcp: connect the public GitHub Copilot MCP server (`https://api.githubcopilot.com/mcp/`). |
| `--tool-access` | Boolean | No |  | `false`, `true` | For KustoClient: let the agent use query tools from this connector (portal 'Allow agent to use query tools'). |
| `--bearer-token` | String | No |  |  | For Mcp: static bearer token, PAT or API key sent with every request. It shows up in shell history, so prefer --bearer-token-file. |
| `--bearer-token-file` | String | No |  |  | For Mcp: path to a file that holds the bearer token, PAT or API key. Surrounding whitespace, such as a trailing newline, is removed. |
| `--managed-identity-auth` | Boolean | No |  | `false`, `true` | For Mcp: authenticate with the agent's managed identity. Use --identity for a user-assigned one. |
| `--mi-token-scope` | String | No |  |  | For Mcp with --managed-identity-auth true: token scope to request. Default: `https://management.azure.com/.default`. On update, a stored scope isn't reused, so pass it again. |
| `--oauth-dcr` | Boolean | No |  | `false`, `true` | For Mcp: use OAuth with dynamic client registration. Finish consent in the portal. |
| `--oauth-scopes` | String | No |  |  | For Mcp with --oauth-dcr: comma-separated OAuth scopes to request. On update, stored scopes aren't reused, so pass them again. |
| `--oauth-client-name` | String | No |  |  | For Mcp with --oauth-dcr: client name to register. Optional. On update, a stored client name isn't reused, so pass it again. |
| `--partner-type` | String | No |  |  | For Mcp: the partner integration this server belongs to, for example DynatraceMcp. |

**Examples**

- Connect Azure Data Explorer

  ```bash
  az sre connector create --agent-name myagent --resource-group myrg \
  --name adx --data-connector-type "Azure Data Explorer"
  ```
- Connect the GitHub MCP server

  ```bash
  az sre connector create --agent-name myagent --resource-group myrg \
  --name github --data-connector-type Mcp --github true
  ```
- Connect a custom MCP server with a bearer token read from a file

  ```bash
  az sre connector create --agent-name myagent --resource-group myrg \
  --name mcp --data-connector-type Mcp \
  --mcp-endpoint "https://myserver.contoso.com/mcp" \
  --bearer-token-file token.txt
  ```
- Connect a Dynatrace MCP server

  ```bash
  az sre connector create --agent-name myagent --resource-group myrg \
  --name dynatrace --data-connector-type Mcp \
  --mcp-endpoint "https://myenv.apps.dynatrace.com/platform-reserved/mcp-gateway/v0.1/servers/dynatrace-mcp/mcp" \
  --bearer-token "$DT_TOKEN" --partner-type DynatraceMcp
  ```
- Connect a custom MCP server with the agent's managed identity

  ```bash
  az sre connector create --agent-name myagent --resource-group myrg \
  --name mcp --data-connector-type Mcp \
  --mcp-endpoint "https://myserver.contoso.com/mcp" \
  --managed-identity-auth true
  ```
- Connect one Kusto cluster and database

  ```bash
  az sre connector create --agent-name myagent --resource-group myrg \
  --name kusto --data-connector-type "Azure Data Explorer" \
  --data-source "https://mycluster.westus.kusto.windows.net/mydatabase"
  ```

### `az sre connector delete`

Delete an Agent Connector.

**Syntax**

`az sre connector delete [--no-wait] --agent-name <value> --name <value> --resource-group <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `--agent-name` | String | Yes |  |  | The name of the Agent |
| `-n`, `--name`, `--connector-name` | String | Yes |  |  | The name of the AgentConnector |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a connector without a prompt

  ```bash
  az sre connector delete -g myrg --agent-name myagent -n conn-kusto --yes
  ```

### `az sre connector list`

List connectors, including OAuth consent status.

consentStatus (Consented/PendingConsent) is shown for EntraOAuth-backed Mcp connectors.

**Syntax**

`az sre connector list [--next-token <value>] [--max-items <value>] --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--next-token` | String | No |  |  | Token to specify where to start paginating. This is the token value from a previously truncated response. |
| `--max-items` | String | No |  |  | Total number of items to return in the command's output. If the total number of items available is more than the value specified, a token is provided in the command's output. To resume pagination, provide the token value in `--next-token` argument of a subsequent command. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's connectors

  ```bash
  az sre connector list -g myrg --agent-name myagent
  ```

### `az sre connector list-secret`

Show a connector with its secrets in plain text.

Unlike 'sre connector show' and 'sre connector list', which leave secret fields out, this command prints every secret the service returns. HTTP request and response tracing is disabled for this command, including with --debug. Store the output securely and never commit it. The service only returns secrets to callers with an admin role on the agent; other callers get an authorization error.

**Syntax**

`az sre connector list-secret --agent-name <value> --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | The name of the Agent |
| `-n`, `--name`, `--connector-name` | String | Yes |  |  | The name of the AgentConnector |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Read back a Kusto connector's secret after creating it

  ```bash
  az sre connector list-secret --agent-name myagent --resource-group myrg --name conn-kusto
  ```

### `az sre connector show`

Show a connector, including OAuth consent status.

consentStatus is shown for EntraOAuth-backed Mcp connectors.

**Syntax**

`az sre connector show --agent-name <value> --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | The name of the Agent |
| `-n`, `--name`, `--connector-name` | String | Yes |  |  | The name of the AgentConnector |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Show one connector

  ```bash
  az sre connector show -g myrg --agent-name myagent -n conn-kusto
  ```

### `az sre connector update`

Update an Agent Connector.

An update sends the whole connector back, and the service never returns a connector's data source or identity, or an MCP connector's endpoint and credentials. So pass --data-source and --identity on every update (null for one the connector doesn't have), and pass all of an MCP connector's --extended-properties, or --mcp-endpoint plus its auth flag. With --mcp-endpoint, the connector's other settings (like partnerType) are kept, and --extended-properties is merged in; custom headers are never returned, so pass them again with --extended-properties '{"headers": {...}}'. These flags only work on Mcp connectors. To change a knowledge source, run 'az sre knowledge create' with --overwrite.

**Syntax**

`az sre connector update [--no-wait] [--add <value>] [--set <value>] [--remove <value>] [--force-string {true,t,yes,y,1,false,f,no,n,0}] --agent-name <value> --name <value> --resource-group <value> [--data-connector-type <value>] [--data-source <value>] [--endpoint <value>] [--extended-properties <json-or-@file>] [--identity <value>] [--partner-type <value>] [--mcp-endpoint <value>] [--bearer-token <value>] [--bearer-token-file <value>] [--managed-identity-auth {false,true}] [--mi-token-scope <value>] [--oauth-dcr {false,true}] [--oauth-scopes <value>] [--oauth-client-name <value>] [--clear-auth {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `--add` | String | No |  |  | Add an object to a list of objects by specifying a path and key value pairs. Example: `--add property.listProperty <key=value, string or JSON string>` |
| `--set` | String | No |  |  | Update an object by specifying a property path and value to set. Example: `--set property1.property2=<value>` |
| `--remove` | String | No |  |  | Remove a property or an element from a list. Example: `--remove property.list <indexToRemove>` OR `--remove propertyToRemove` |
| `--force-string` | String | No |  | `true`, `t`, `yes`, `y`, `1`, `false`, `f`, `no`, `n`, `0` | When using 'set' or 'add', preserve string literals instead of attempting to convert to JSON. |
| `--agent-name` | String | Yes |  |  | The name of the Agent |
| `-n`, `--name`, `--connector-name` | String | Yes |  |  | The name of the AgentConnector |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--data-connector-type` | String | No |  |  | Connector type, by portal name (case-insensitive): Azure Data Explorer, Database query connector (user), Log Analytics Workspace, Application Insights, MonitorClient, MCP server, EV2, Azure DevOps AI Search, IcM connector, DGrep, Geneva Metrics, S360 connector. For knowledge sources use 'az sre knowledge create'. Set up Outlook, Teams and other managed connectors in the portal. |
| `--data-source` | String | No |  |  | Connection string or endpoint. For Kusto, include the database: `https://cluster.kusto.windows.net/database`. On update, pass it again, or null for none. |
| `--endpoint` | String | No |  |  | Endpoint URL, used by endpoint-based connector types such as Mcp. |
| `--extended-properties` | Dictionary | No |  |  | Type-specific settings as JSON or shorthand. On update, this replaces all of them, unless an MCP flag is used; then it's merged with the settings the service returns. |
| `--identity` | String | No |  |  | 'system' for the agent's system-assigned identity, or a user-assigned identity resource ID. On create, leave it out for no identity; on update, pass it again, or null for none. |
| `--partner-type` | String | No |  |  | For Mcp: the partner integration this server belongs to, for example DynatraceMcp. |
| `--mcp-endpoint` | String | No |  |  | For Mcp: the MCP server's HTTP endpoint URL. With the auth flags, pass the endpoint here or in --extended-properties; the service never returns it. |
| `--bearer-token` | String | No |  |  | For Mcp: static bearer token, PAT or API key sent with every request. It shows up in shell history, so prefer --bearer-token-file. |
| `--bearer-token-file` | String | No |  |  | For Mcp: path to a file that holds the bearer token, PAT or API key. Surrounding whitespace, such as a trailing newline, is removed. |
| `--managed-identity-auth` | Boolean | No |  | `false`, `true` | For Mcp: authenticate with the agent's managed identity. Use --identity for a user-assigned one. |
| `--mi-token-scope` | String | No |  |  | For Mcp with --managed-identity-auth true: token scope to request. Default: `https://management.azure.com/.default`. On update, a stored scope isn't reused, so pass it again. |
| `--oauth-dcr` | Boolean | No |  | `false`, `true` | For Mcp: use OAuth with dynamic client registration. Finish consent in the portal. |
| `--oauth-scopes` | String | No |  |  | For Mcp with --oauth-dcr: comma-separated OAuth scopes to request. On update, stored scopes aren't reused, so pass them again. |
| `--oauth-client-name` | String | No |  |  | For Mcp with --oauth-dcr: client name to register. Optional. On update, a stored client name isn't reused, so pass it again. |
| `--clear-auth` | Boolean | No |  | `false`, `true` | For Mcp: remove the connector's auth and save it without any. Needs the endpoint, like the auth flags. |

**Examples**

- Point a Kusto connector that has no identity at a different database

  ```bash
  az sre connector update -g myrg --agent-name myagent -n conn-kusto \
  --data-source "https://mycluster.westus.kusto.windows.net/otherdb" --identity null
  ```
- Rotate an MCP connector's bearer token, read from a file

  ```bash
  az sre connector update -g myrg --agent-name myagent -n mcp --identity null \
  --mcp-endpoint "https://myserver.contoso.com/mcp" --bearer-token-file token.txt
  ```
- Mark an MCP connector as a Dynatrace integration

  ```bash
  az sre connector update -g myrg --agent-name myagent -n dynatrace --partner-type DynatraceMcp \
  --data-source "$DT_MCP_URL" --identity null --extended-properties "@dynatrace-mcp.json"
  ```

### `az sre connector wait`

Wait for a connector to reach a desired state.

**Syntax**

`az sre connector wait --agent-name <value> --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | The name of the Agent |
| `-n`, `--name`, `--connector-name` | String | Yes |  |  | The name of the AgentConnector |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Wait until a connector created with --no-wait exists

  ```bash
  az sre connector wait -g myrg --agent-name myagent -n conn-kusto --created
  ```

## `az sre endpoint`

Resolve the URL used to actually talk to an SRE Agent's data plane.

Use 'sre endpoint show' to look up and save that live endpoint.

| Verb | Exact syntax |
| --- | --- |
| `show` | `az sre endpoint show --name <value> --resource-group <value> [--data-plane-audience <value>]` |

### `az sre endpoint show`

Save an agent's data-plane endpoint for other tools.

Like 'az aks get-credentials', it writes the connection details that data-plane tools read.

**Syntax**

`az sre endpoint show --name <value> --resource-group <value> [--data-plane-audience <value>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent to connect to. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--data-plane-audience` | String | No | https://azuresre.dev |  | Audience for the data-plane access token. |

**Examples**

- Resolve and save the data-plane endpoint for an agent

  ```bash
  az sre endpoint show --agent-name myagent --resource-group myrg
  ```

## `az sre hook`

Manage lifecycle hooks that run a prompt or script at a specific agent event.

Fires on one of four events (Start, PreToolUse, PostToolUse, Stop) and runs either an LLM prompt or a bash/Python command. See 'sre hook create -h' for the full --value shape and the portal-vs-API note.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre hook create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]` |
| `delete` | `az sre hook delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre hook list --name <value> --resource-group <value>` |
| `show` | `az sre hook show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre hook create`

Create or update a hook.

**Syntax**

`az sre hook create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Hook configuration as JSON: eventType, activationMode, description and a nested "hook" object. hook.matcher is required for PreToolUse and PostToolUse. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |

**Examples**

- Run a prompt after every Bash tool call

  ```bash
  cat > hook.json <<'JSON'
  {"eventType": "PostToolUse", "activationMode": "always", "description": "Flag risky commands",
  "hook": {"type": "prompt", "prompt": "Warn if the last tool call looks destructive.",
  "matcher": "Bash.*", "failMode": "Allow"}}
  JSON
  az sre hook create --agent-name myagent --resource-group myrg --name post-tool-check \
  --value @hook.json
  ```
- Run a command instead of a prompt

  ```bash
  cat > command-hook.json <<'JSON'
  {"eventType": "PostToolUse", "activationMode": "always",
  "hook": {"type": "command", "script": "#!/usr/bin/env python3\nimport json\nprint(json.dumps({'decision': 'allow'}))",
  "matcher": "Bash.*", "timeout": 30}}
  JSON
  az sre hook create --agent-name myagent --resource-group myrg --name post-tool-command \
  --value @command-hook.json
  ```

### `az sre hook delete`

Delete a hook.

**Syntax**

`az sre hook delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a hook

  ```bash
  az sre hook delete -g myrg --agent-name myagent --name post-tool-check
  ```

### `az sre hook list`

List hooks.

**Syntax**

`az sre hook list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's hooks

  ```bash
  az sre hook list -g myrg --agent-name myagent
  ```

### `az sre hook show`

Show a hook.

**Syntax**

`az sre hook show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one hook

  ```bash
  az sre hook show -g myrg --agent-name myagent --name post-tool-check
  ```

## `az sre identity`

Manage the agent's own managed identity.

Used for the agent's Azure RBAC-gated calls. Not to be confused with 'sre access' (who can manage/use the agent) or 'sre repo connect' (repo auth).

| Verb | Exact syntax |
| --- | --- |
| `assign` | `az sre identity assign [--no-wait] --name <value> --resource-group <value> [--system-assigned <value>] [--user-assigned <json-or-@file>]` |
| `remove` | `az sre identity remove [--no-wait] --name <value> --resource-group <value> [--system-assigned <value>] [--user-assigned <json-or-@file>]` |
| `show` | `az sre identity show --name <value> --resource-group <value>` |
| `wait` | `az sre identity wait --name <value> --resource-group <value>` |

### `az sre identity assign`

Assign a managed identity to an agent.

**Syntax**

`az sre identity assign [--no-wait] --name <value> --resource-group <value> [--system-assigned <value>] [--user-assigned <json-or-@file>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--system-assigned`, `--mi-system-assigned` | String | No |  |  | Set the system managed identity. |
| `--user-assigned`, `--mi-user-assigned` | List | No |  |  | Set the user managed identities. |

**Examples**

- Turn on the agent's system-assigned identity

  ```bash
  az sre identity assign --agent-name myagent --resource-group myrg --system-assigned
  ```
- Assign one or more user-assigned identities

  ```bash
  az sre identity assign --agent-name myagent --resource-group myrg \
  --user-assigned "/subscriptions/.../resourceGroups/myrg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/myid"
  ```

### `az sre identity remove`

Remove a managed identity from an agent.

**Syntax**

`az sre identity remove [--no-wait] --name <value> --resource-group <value> [--system-assigned <value>] [--user-assigned <json-or-@file>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--no-wait` | Flag | No |  |  | Do not wait for the long-running operation to finish. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--system-assigned`, `--mi-system-assigned` | String | No |  |  | Set the system managed identity. |
| `--user-assigned`, `--mi-user-assigned` | List | No |  |  | Set the user managed identities. |

**Examples**

- Turn off the agent's system-assigned identity

  ```bash
  az sre identity remove --agent-name myagent --resource-group myrg --system-assigned
  ```
- Remove one user-assigned identity

  ```bash
  az sre identity remove --agent-name myagent --resource-group myrg \
  --user-assigned "/subscriptions/.../resourceGroups/myrg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/myid"
  ```

### `az sre identity show`

Show the managed identities assigned to an agent.

**Syntax**

`az sre identity show --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Show an agent's identities

  ```bash
  az sre identity show -g myrg --agent-name myagent
  ```

### `az sre identity wait`

Wait for an agent's identity update to finish.

**Syntax**

`az sre identity wait --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | The name of the Agent |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Wait for an identity assignment started with --no-wait

  ```bash
  az sre identity wait -g myrg --agent-name myagent --updated
  ```

## `az sre instructions`

Manage named, reusable prompt snippets ('commonPrompts').

Important: these snippets aren't the portal's "Custom instructions" text box. That box is the 'customInstructions' field in the agent's global settings. Set it with 'az sre agent settings update'.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre instructions create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]` |
| `delete` | `az sre instructions delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre instructions list --name <value> --resource-group <value>` |
| `show` | `az sre instructions show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre instructions create`

Create or update a reusable prompt snippet.

Important: this doesn't set the portal's "Custom instructions" text box. To set that, use 'az sre agent settings update'. Use the same --name (e.g. "default") each time to update a given snippet in place, or pass --overwrite to replace an existing one.

**Syntax**

`az sre instructions create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Prompt snippet as JSON: {"prompt": "..."}. For custom instructions, use 'az sre agent settings update'. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |

**Examples**

- Set the portal's global custom instructions with agent settings

  ```bash
  az sre agent settings update -g myrg --agent-name myagent \
  --value '{"customInstructions": "Always cite the runbook section you used."}'
  ```
- Create a named, reusable prompt snippet

  ```bash
  az sre instructions create -g myrg --agent-name myagent --name default \
  --value '{"prompt": "Always cite the runbook section you used."}'
  ```
- In Windows PowerShell, pass a JSON file

  ```powershell
  '{"prompt": "Be concise."}' | Set-Content -Path "$env:TEMP\instructions.json"
  az sre instructions create -g myrg --agent-name myagent --name default --value "@$env:TEMP\instructions.json" --overwrite true
  ```
- In Windows PowerShell, pass inline JSON through cmd /c

  ```powershell
  cmd /c 'az sre instructions create --agent-name myagent --resource-group myrg --name default --value "{\"prompt\": \"Be concise.\"}" --overwrite true'
  ```

### `az sre instructions delete`

Delete a named, reusable prompt snippet ('commonPrompts').

Important: this doesn't clear the portal's "Custom instructions" box (see 'az sre instructions create -h'). To clear that box, run 'az sre agent settings update --value \'{"customInstructions": ""}\''.

**Syntax**

`az sre instructions delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a reusable prompt snippet

  ```bash
  az sre instructions delete -g myrg --agent-name myagent --name default
  ```

### `az sre instructions list`

List an agent's reusable prompt snippets.

Important: these aren't the portal's "Custom instructions" box (see 'az sre instructions create -h').

**Syntax**

`az sre instructions list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's reusable prompt snippets

  ```bash
  az sre instructions list -g myrg --agent-name myagent
  ```

### `az sre instructions show`

Show a named, reusable prompt snippet ('commonPrompts').

Important: this isn't the portal's "Custom instructions" box (see 'az sre instructions create -h'). To see that box's text, run 'az sre agent settings show' and read its 'customInstructions' field.

**Syntax**

`az sre instructions show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show a reusable prompt snippet

  ```bash
  az sre instructions show -g myrg --agent-name myagent --name default
  ```

## `az sre knowledge`

Add files or web pages the agent can read and reason over.

Use 'sre knowledge create --type file' or '--type webpage' to add one. Repository knowledge sources use 'sre repo connect' instead.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre knowledge create --agent-name <value> --resource-group <value> --name <value> --type {file,text,webpage,repository} [--file-path <value>] [--url <value>] [--data-source <value>] [--overwrite {false,true}]` |
| `delete` | `az sre knowledge delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre knowledge list --name <value> --resource-group <value>` |
| `show` | `az sre knowledge show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre knowledge create`

Add a knowledge source (file or web page) to an SRE Agent.

**Syntax**

`az sre knowledge create --agent-name <value> --resource-group <value> --name <value> --type {file,text,webpage,repository} [--file-path <value>] [--url <value>] [--data-source <value>] [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n` | String | Yes |  |  | Name of this knowledge source. |
| `--type` | String | Yes |  | `file`, `text`, `webpage`, `repository` | Kind of knowledge source. One of: file, repository, text, webpage. |
| `--file-path` | String | No |  |  | Local file to ingest. Required for --type file/text. With --type file, the agent indexes only .md, .txt, .pdf, .docx, .pptx, .xlsx, .doc, .ppt, .xls, .png, .jpg, .jpeg, .gif, .webp, .bmp, .tiff, .tif, .json, .csv, .log, .yaml, .yml, .xml, .ini, .conf, .cfg, .config, .properties files; add other text files, such as code, with --type text. |
| `--url` | String | No |  |  | Web page URL to ingest. Required for --type webpage. Cannot be combined with --data-source. |
| `--data-source` | String | No |  |  | Raw --data-source passthrough, for --type repository or any case --file-path/--url don't cover. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing knowledge source of the same name. Other connector types are never replaced. |

**Examples**

- Add a local file as a knowledge source

  ```bash
  az sre knowledge create --agent-name myagent --resource-group myrg \
  --name runbook-md --type file --file-path ./runbook.md
  ```
- Add a web page as a knowledge source

  ```bash
  az sre knowledge create --agent-name myagent --resource-group myrg \
  --name docs-site --type webpage --url https://learn.microsoft.com/azure/
  ```

### `az sre knowledge delete`

Remove a knowledge source.

**Syntax**

`az sre knowledge delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n` | String | Yes |  |  | Name of the knowledge source. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Remove a knowledge source

  ```bash
  az sre knowledge delete -g myrg --agent-name myagent --name docs-site
  ```

### `az sre knowledge list`

List an SRE Agent's knowledge sources (files and web pages).

**Syntax**

`az sre knowledge list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List knowledge sources

  ```bash
  az sre knowledge list -g myrg --agent-name myagent
  ```

### `az sre knowledge show`

Show a knowledge source.

**Syntax**

`az sre knowledge show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n` | String | Yes |  |  | Name of the knowledge source. |

**Examples**

- Show one knowledge source

  ```bash
  az sre knowledge show -g myrg --agent-name myagent --name docs-site
  ```

## `az sre managed-resource`

Let the agent monitor resources outside its resource group.

Grants/revokes the built-in 'Reader' + 'Monitoring Contributor' roles together on a subscription, resource group, or management group. Use --roles to pick different roles, e.g. Contributor or Monitoring Reader. Targets the identity the agent is configured to use, like the portal. Use `--identity system` or `--identity <user-assigned identity ARM ID>` to target a different attached identity.

| Verb | Exact syntax |
| --- | --- |
| `grant` | `az sre managed-resource grant [--identity <value>] --name <value> --resource-group <value> [--scope <value>] [--target-subscription <value>] [--target-rg <value>] [--management-group <value>] [--roles <json-or-@file>]` |
| `list` | `az sre managed-resource list [--identity <value>] --name <value> --resource-group <value>` |
| `revoke` | `az sre managed-resource revoke [--identity <value>] --name <value> --resource-group <value> [--scope <value>] [--target-subscription <value>] [--target-rg <value>] [--management-group <value>] [--roles <json-or-@file>]` |

### `az sre managed-resource grant`

Give the agent Reader and Monitoring Contributor on a scope.

Targets the identity the agent is configured to use, like the portal. Use --identity to select another attached identity without changing the agent's configuration. Use --roles to grant a different set of roles.

**Syntax**

`az sre managed-resource grant [--identity <value>] --name <value> --resource-group <value> [--scope <value>] [--target-subscription <value>] [--target-rg <value>] [--management-group <value>] [--roles <json-or-@file>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--identity` | String | No |  |  | Agent identity to target: 'system', or the full ARM resource ID of an assigned user-assigned identity. Default: the identity the agent is configured to use (knowledgeGraphConfiguration.identity, the one the portal uses). Does not change the agent's configuration. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Resource group of the SRE Agent (NOT the target scope -- use --target-rg for that). |
| `--scope` | String | No |  |  | Full resource ID of the scope to grant access on/from. Alternative to --target-subscription/--target-rg/--management-group. |
| `--target-subscription` | String | No |  |  | Target subscription name or ID. Alone: subscription scope. With --target-rg: resource-group scope. |
| `--target-rg` | String | No |  |  | Target resource group name (requires --target-subscription). Distinct from --resource-group, which locates the agent itself. |
| `--management-group` | String | No |  |  | Target management group name/ID. |
| `--roles` | List | No |  |  | Roles to grant instead of the default Reader and Monitoring Contributor, e.g. --roles Reader "Monitoring Reader" Contributor. Names or role definition IDs. |

**Examples**

- Grant on a subscription

  ```bash
  az sre managed-resource grant --agent-name myagent --resource-group myrg \
  --target-subscription my-sub
  ```
- Grant Reader, Monitoring Reader and Contributor on a resource group

  ```bash
  az sre managed-resource grant --agent-name myagent --resource-group myrg \
  --target-subscription my-sub --target-rg monitored-rg \
  --roles Reader "Monitoring Reader" Contributor
  ```
- Grant on a resource group

  ```bash
  az sre managed-resource grant --agent-name myagent --resource-group myrg \
  --target-subscription my-sub --target-rg monitored-rg
  ```
- Grant on a management group

  ```bash
  az sre managed-resource grant --agent-name myagent --resource-group myrg \
  --management-group my-mg
  ```
- Grant an assigned user-assigned identity access to a resource group

  ```bash
  az sre managed-resource grant -g myrg --agent-name myagent \
  --identity /subscriptions/<sub-id>/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runtime \
  --target-subscription my-sub --target-rg monitored-rg
  ```

### `az sre managed-resource list`

List the scopes the agent's managed identity can access.

Shows role assignments under the current subscription for the selected identity, not just Reader and Monitoring Contributor. Defaults to the identity the agent is configured to use. Use --identity to select another attached identity.

**Syntax**

`az sre managed-resource list [--identity <value>] --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--identity` | String | No |  |  | Agent identity to target: 'system', or the full ARM resource ID of an assigned user-assigned identity. Default: the identity the agent is configured to use (knowledgeGraphConfiguration.identity, the one the portal uses). Does not change the agent's configuration. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Resource group of the SRE Agent. |

**Examples**

- List what an agent can currently monitor

  ```bash
  az sre managed-resource list --agent-name myagent --resource-group myrg
  ```
- List an assigned user-assigned identity's role assignments

  ```bash
  az sre managed-resource list -g myrg --agent-name myagent \
  --identity /subscriptions/<sub-id>/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runtime
  ```

### `az sre managed-resource revoke`

Remove the agent's Reader and Monitoring Contributor on a scope.

Only removes these two roles (or the ones given with --roles) for the selected identity on the exact requested scope. Other identities, roles, and scopes are unaffected. Defaults to the identity the agent is configured to use.

**Syntax**

`az sre managed-resource revoke [--identity <value>] --name <value> --resource-group <value> [--scope <value>] [--target-subscription <value>] [--target-rg <value>] [--management-group <value>] [--roles <json-or-@file>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--identity` | String | No |  |  | Agent identity to target: 'system', or the full ARM resource ID of an assigned user-assigned identity. Default: the identity the agent is configured to use (knowledgeGraphConfiguration.identity, the one the portal uses). Does not change the agent's configuration. |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Resource group of the SRE Agent (NOT the target scope -- use --target-rg for that). |
| `--scope` | String | No |  |  | Full resource ID of the scope to revoke access on/from. Alternative to --target-subscription/--target-rg/--management-group. |
| `--target-subscription` | String | No |  |  | Target subscription name or ID. Alone: subscription scope. With --target-rg: resource-group scope. |
| `--target-rg` | String | No |  |  | Target resource group name (requires --target-subscription). Distinct from --resource-group, which locates the agent itself. |
| `--management-group` | String | No |  |  | Target management group name/ID. |
| `--roles` | List | No |  |  | Roles to revoke instead of the default Reader and Monitoring Contributor, e.g. --roles Reader "Monitoring Reader" Contributor. Names or role definition IDs. |

**Examples**

- Revoke access to a resource group

  ```bash
  az sre managed-resource revoke --agent-name myagent --resource-group myrg \
  --target-subscription my-sub --target-rg monitored-rg
  ```
- Revoke an assigned user-assigned identity's access

  ```bash
  az sre managed-resource revoke -g myrg --agent-name myagent \
  --identity /subscriptions/<sub-id>/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runtime \
  --target-subscription my-sub --target-rg monitored-rg
  ```

## `az sre network`

Control an SRE Agent's sandbox networking (preview).

Configures VNet injection and outbound egress for the agent's own sandboxed tool and code execution. It doesn't control inbound access to the agent resource.

| Verb | Exact syntax |
| --- | --- |
| `show` | `az sre network show --name <value> --resource-group <value>` |
| `update` | `az sre network update --name <value> --resource-group <value> [--vnet-configuration <json-or-@file>] [--sandbox-configuration <json-or-@file>] [--replace-allowed-hosts {false,true}]` |

### `az sre network show`

Show VNet injection and sandbox egress settings (preview).

'az sre agent show' omits these because it uses an older API version.

**Syntax**

`az sre network show --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent to show networking settings for. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Show an agent's networking settings

  ```bash
  az sre network show --name myagent --resource-group myrg
  ```

### `az sre network update`

Configure VNet injection and sandbox egress (preview).

Hosts in allowed-hosts are added to the agent's current allowed hosts, which start with the service's defaults. Pass --replace-allowed-hosts to replace the list instead. Other lists you pass, such as allowed-registries, replace the stored list.

**Syntax**

`az sre network update --name <value> --resource-group <value> [--vnet-configuration <json-or-@file>] [--sandbox-configuration <json-or-@file>] [--replace-allowed-hosts {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent to configure networking on. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--vnet-configuration` | Object | No |  |  | VNet injection for the agent itself. Shorthand JSON, e.g. --vnet-configuration "{subnet-resource-id:/subscriptions/.../subnets/mysubnet}". |
| `--sandbox-configuration` | Object | No |  |  | Sandbox egress and packages. Shorthand, e.g. "{egress:{mode:Limited,allowed-hosts:[example.com]}}". |
| `--replace-allowed-hosts` | Boolean | No |  | `false`, `true` | Replace the agent's allowed hosts with the allowed-hosts list instead of adding to them. A warning names the hosts this removes, which can include the service's defaults. |

**Examples**

- Allow the agent's sandbox to reach one more host

  ```bash
  az sre network update --name myagent --resource-group myrg \
  --sandbox-configuration "{egress:{mode:Limited,allowed-hosts:[example.com]}}"
  ```
- Replace the allowed hosts, including the service's defaults, with one host

  ```bash
  az sre network update --name myagent --resource-group myrg --replace-allowed-hosts \
  --sandbox-configuration "{egress:{mode:Limited,allowed-hosts:[example.com]}}"
  ```

## `az sre plugin`

Manage community plugins that add skills, tools, and integrations.

Two separate steps: connecting a marketplace (a GitHub/Azure DevOps/GitLab repo of plugins, via 'sre plugin marketplace') and installing a specific plugin from one (via 'sre plugin install').

| Subgroup | Summary |
| --- | --- |
| `install` | Install a specific plugin from an already-connected marketplace. |
| `marketplace` | Connect a repo of plugins as a marketplace the agent can install from. |

## `az sre repo`

Connect a code repository so the agent can read source during investigations.

Supports GitHub and Azure DevOps. GitLab isn't exposed by this CLI yet.

| Verb | Exact syntax |
| --- | --- |
| `connect` | `az sre repo connect --agent-name <value> --resource-group <value> --repo-url <value> [--provider {GitHub,AzureDevOps}] [--display-name <value>] [--overwrite {false,true}] [--branch <value>] [--github-token <value>] [--devops-organization <value>] [--devops-auth-type {pat,managed-identity}] [--devops-identity <value>] [--devops-federated-client-id <value>] [--devops-federated-tenant-id <value>]` |

### `az sre repo connect`

Connect a GitHub or Azure DevOps repo to an agent.

The agent keeps one credential for all its GitHub repositories, and one per Azure DevOps organization. Each run saves a new one, which the agent's other repos on that host or organization then use too. For GitHub, the command uses --github-token, or the GITHUB_TOKEN or GH_TOKEN environment variable. If none is set, it shows a one-time code and opens GitHub's sign-in page in your browser. Enter the code there before it expires (15 minutes). For Azure DevOps, it creates a personal access token (PAT) that expires after 30 days; run the command again before then, or use a managed identity, which doesn't expire. Running the command again for the same repo keeps its other settings, such as the branch and sparse checkout paths.

**Syntax**

`az sre repo connect --agent-name <value> --resource-group <value> --repo-url <value> [--provider {GitHub,AzureDevOps}] [--display-name <value>] [--overwrite {false,true}] [--branch <value>] [--github-token <value>] [--devops-organization <value>] [--devops-auth-type {pat,managed-identity}] [--devops-identity <value>] [--devops-federated-client-id <value>] [--devops-federated-tenant-id <value>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--repo-url` | String | Yes |  |  | HTTPS clone URL of the repo, on github.com, dev.azure.com or `<organization>.visualstudio.com`. Don't put a user name or token in it. |
| `--provider` | String | No |  | `GitHub`, `AzureDevOps` | Repo provider. Detected from --repo-url's host; if given, it must match that host. |
| `--display-name`, `--name`, `-n` | String | No |  |  | Display name for the repo, unique on the agent. Defaults to the repo name from --repo-url (without .git). |
| `--overwrite` | Boolean | No |  | `false`, `true` | Replace a repo with the same display name that points to a different URL. Without this flag, the command stops before saving anything. |
| `--branch` | String | No |  |  | Branch to check out. Defaults to the repo's default branch, or to the saved branch when you connect the same repo again. |
| `--github-token` | String | No |  |  | GitHub token. Defaults to GITHUB_TOKEN or GH_TOKEN, then to browser sign-in with a one-time code. It is stored on the agent and used for all its GitHub repos, so it must be able to read every one of them. |
| `--devops-organization` | String | No |  |  | Azure DevOps organization. Default: taken from --repo-url. |
| `--devops-auth-type` | String | No | pat | `pat`, `managed-identity` | Azure DevOps auth method. pat creates a PAT that expires after 30 days. Use managed-identity if your org blocks PAT creation, or to avoid the expiry. |
| `--devops-identity` | String | No |  |  | Managed identity resource ID. Required with --devops-auth-type managed-identity. |
| `--devops-federated-client-id`, `--devops-fed-client-id` | String | No |  |  | Federated client ID, for an identity in a different tenant. Use with --devops-federated-tenant-id. |
| `--devops-federated-tenant-id`, `--devops-fed-tenant-id` | String | No |  |  | Federated tenant ID. Use with --devops-federated-client-id. |

**Examples**

- Connect a GitHub repo

  ```bash
  az sre repo connect --agent-name myagent --resource-group myrg \
  --repo-url https://github.com/contoso/my-service
  ```
- Connect a GitHub repo in CI, with the token in GITHUB_TOKEN

  ```bash
  az sre repo connect --agent-name myagent --resource-group myrg \
  --repo-url https://github.com/contoso/my-service
  ```
- Connect a second repo whose name is already taken on the agent

  ```bash
  az sre repo connect --agent-name myagent --resource-group myrg \
  --repo-url https://github.com/fabrikam/my-service --display-name fabrikam-my-service
  ```
- Connect an Azure DevOps repo

  ```bash
  az sre repo connect --agent-name myagent --resource-group myrg \
  --repo-url https://dev.azure.com/contoso/my-project/_git/my-repo
  ```
- Connect an Azure DevOps repo with a managed identity

  ```bash
  az sre repo connect --agent-name myagent --resource-group myrg \
  --repo-url https://dev.azure.com/contoso/my-project/_git/my-repo \
  --devops-auth-type managed-identity --devops-identity <agent-identity-resource-id>
  ```

## `az sre response-plan`

Route incidents to a subagent (portal: Triggers & response plans).

Match criteria use ARM; linked instructions use the agent API.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre response-plan create --agent-name <value> --resource-group <value> --name <value> --platform <value> --subagent <value> [--display-name <value>] [--priority <json-or-@file>] [--title-contains <value>] [--title-not-contains <json-or-@file>] [--incident-type <json-or-@file>] [--impacted-service <value>] [--owning-team <json-or-@file>] [--merge-enabled {false,true}] [--merge-window-hours <integer>] [--max-investigation-attempts <integer>] [--alert-id <value>] [--target-resource-type <value>] [--target-resource <value>] [--instructions <value>] [--processing-guide <json-or-@file>] [--mode <value>] [--disabled {false,true}] [--overwrite {false,true}]` |
| `delete` | `az sre response-plan delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `disable` | `az sre response-plan disable --agent-name <value> --resource-group <value> --name <value>` |
| `enable` | `az sre response-plan enable --agent-name <value> --resource-group <value> --name <value>` |
| `list` | `az sre response-plan list [--name <value>] [--resource-group <value>] [--agent-url <value>]` |
| `show` | `az sre response-plan show [--agent-name <value>] [--resource-group <value>] [--agent-url <value>] --name <value>` |
| `update` | `az sre response-plan update --agent-name <value> --resource-group <value> --name <value> [--platform <value>] [--subagent <value>] [--mode <value>] [--display-name <value>] [--priority <json-or-@file>] [--title-contains <value>] [--title-not-contains <json-or-@file>] [--incident-type <json-or-@file>] [--impacted-service <value>] [--owning-team <json-or-@file>] [--merge-enabled {false,true}] [--merge-window-hours <integer>] [--max-investigation-attempts <integer>] [--alert-id <value>] [--target-resource-type <value>] [--target-resource <value>] [--instructions <value>] [--processing-guide <json-or-@file>]` |

### `az sre response-plan create`

Create or update an incident response plan.

Routes matching incidents to a subagent. Connect the incident platform and create the subagent first.

**Syntax**

`az sre response-plan create --agent-name <value> --resource-group <value> --name <value> --platform <value> --subagent <value> [--display-name <value>] [--priority <json-or-@file>] [--title-contains <value>] [--title-not-contains <json-or-@file>] [--incident-type <json-or-@file>] [--impacted-service <value>] [--owning-team <json-or-@file>] [--merge-enabled {false,true}] [--merge-window-hours <integer>] [--max-investigation-attempts <integer>] [--alert-id <value>] [--target-resource-type <value>] [--target-resource <value>] [--instructions <value>] [--processing-guide <json-or-@file>] [--mode <value>] [--disabled {false,true}] [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of the response plan. |
| `--platform` | String | Yes |  |  | Incident platform: AzMonitor, PagerDuty, ServiceNow, Icm. Icm is Microsoft-internal only. |
| `--subagent` | String | Yes |  |  | Name of the existing subagent that handles matched incidents. Use meta_agent for the main agent. |
| `--display-name` | String | No |  |  | Name the portal shows for the plan. Default: the plan's --name. |
| `--priority` | List | No |  |  | Space-separated priority or severity levels to match (for example Sev0 Sev1 or P1 P2; IcM severities are plain numbers such as 3 4). Default: all. |
| `--title-contains` | String | No |  |  | Only match incidents whose title contains this text. |
| `--title-not-contains` | List | No |  |  | Space-separated texts; skip incidents whose title contains any of them. |
| `--incident-type` | List | No |  |  | Space-separated incident types to match (for example LiveSite). Required with --platform Icm. Portal: Incident type. |
| `--impacted-service` | String | No |  |  | Only match incidents for this service. Portal: Owning service. |
| `--owning-team` | List | No |  |  | Space-separated owning team IDs (IcM team IDs are numeric). Portal: Owning team. |
| `--merge-enabled` | Boolean | No |  | `false`, `true` | Merge related incidents into one investigation thread. Service default: true. |
| `--merge-window-hours` | Integer | No |  |  | Hours within which related incidents are merged. Service default: 3. |
| `--max-investigation-attempts`, `--max-attempts` | Integer | No |  |  | How many times the agent automatically investigates a matched incident. Service default: 3. |
| `--alert-id` | String | No |  |  | Only match incidents raised by this alert rule (its resource ID). |
| `--target-resource-type` | String | No |  |  | Only match alerts on this resource type, for example Microsoft.App/containerApps. |
| `--target-resource` | String | No |  |  | Only match alerts on this resource. |
| `--instructions` | String | No |  |  | Custom instructions the subagent follows for matched incidents. |
| `--processing-guide` | List | No |  |  | Quoted step-by-step guidance for the subagent, one value per step. |
| `--mode` | String | No | autonomous |  | Agent autonomy: autonomous (portal default) or review (agent proposes, you approve). |
| `--disabled` | Boolean | No |  | `false`, `true` | Create the plan turned off. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing response plan, or taking over instructions with the plan's name that aren't linked to a plan. |

**Examples**

- Route high-severity Azure Monitor incidents to a subagent in review mode

  ```bash
  az sre response-plan create -g myrg --agent-name myagent -n sev1-api \
  --platform AzMonitor --subagent incident-responder --priority Sev0 Sev1 \
  --title-contains api --mode review
  ```
- Skip noisy incidents and give the subagent step-by-step guidance

  ```bash
  az sre response-plan create -g myrg --agent-name myagent -n api-errors \
  --platform AzMonitor --subagent incident-responder --priority Sev1 Sev2 \
  --title-not-contains test synthetic \
  --processing-guide "Check recent deployments" "Query error rates in App Insights"
  ```
- Change an existing plan

  ```bash
  az sre response-plan update -g myrg --agent-name myagent -n api-errors --mode autonomous
  ```

### `az sre response-plan delete`

Delete a response plan and its linked instructions.

**Syntax**

`az sre response-plan delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of the response plan. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a plan

  ```bash
  az sre response-plan delete -g myrg --agent-name myagent -n sev1-api
  ```

### `az sre response-plan disable`

Turn off a response plan without deleting it.

**Syntax**

`az sre response-plan disable --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this incident filter. |

**Examples**

- Disable a plan

  ```bash
  az sre response-plan disable -g myrg --agent-name myagent -n sev1-api
  ```

### `az sre response-plan enable`

Turn on a response plan.

**Syntax**

`az sre response-plan enable --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this incident filter. |

**Examples**

- Enable a plan

  ```bash
  az sre response-plan enable -g myrg --agent-name myagent -n sev1-api
  ```

### `az sre response-plan list`

List response plans.

**Syntax**

`az sre response-plan list [--name <value>] [--resource-group <value>] [--agent-url <value>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | No |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | No |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--agent-url` | String | No |  |  | Agent endpoint URL (`https://<agent>.<hash>.<region>.azuresre.ai`) for a shared agent that is not in your subscription. Read-only commands only. |

**Examples**

- List an agent's response plans

  ```bash
  az sre response-plan list -g myrg --agent-name myagent
  ```

### `az sre response-plan show`

Show a response plan and its instructions.

**Syntax**

`az sre response-plan show [--agent-name <value>] [--resource-group <value>] [--agent-url <value>] --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | No |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | No |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--agent-url` | String | No |  |  | Agent endpoint URL (`https://<agent>.<hash>.<region>.azuresre.ai`) for a shared agent that is not in your subscription. Read-only commands only. |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of the response plan. |

**Examples**

- Show one plan

  ```bash
  az sre response-plan show -g myrg --agent-name myagent -n sev1-api
  ```

### `az sre response-plan update`

Update a response plan. Only the flags you pass change.

Passing a list flag (for example --priority) replaces that whole list. Pass an empty value, such as --title-contains="" or --instructions="", to remove a criterion or the instructions. Use 'enable' or 'disable' to turn a plan on or off.

**Syntax**

`az sre response-plan update --agent-name <value> --resource-group <value> --name <value> [--platform <value>] [--subagent <value>] [--mode <value>] [--display-name <value>] [--priority <json-or-@file>] [--title-contains <value>] [--title-not-contains <json-or-@file>] [--incident-type <json-or-@file>] [--impacted-service <value>] [--owning-team <json-or-@file>] [--merge-enabled {false,true}] [--merge-window-hours <integer>] [--max-investigation-attempts <integer>] [--alert-id <value>] [--target-resource-type <value>] [--target-resource <value>] [--instructions <value>] [--processing-guide <json-or-@file>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of the response plan. |
| `--platform` | String | No |  |  | Incident platform: AzMonitor, PagerDuty, ServiceNow, Icm. |
| `--subagent` | String | No |  |  | Name of the existing subagent that handles matched incidents. Use meta_agent for the main agent. |
| `--mode` | String | No |  |  | Agent autonomy: autonomous or review. |
| `--display-name` | String | No |  |  | Name the portal shows for the plan. |
| `--priority` | List | No |  |  | Space-separated priority or severity levels to match (for example Sev0 Sev1 or P1 P2; IcM severities are plain numbers such as 3 4). Default: all. |
| `--title-contains` | String | No |  |  | Only match incidents whose title contains this text. |
| `--title-not-contains` | List | No |  |  | Space-separated texts; skip incidents whose title contains any of them. |
| `--incident-type` | List | No |  |  | Space-separated incident types to match (for example LiveSite). Required with --platform Icm. Portal: Incident type. |
| `--impacted-service` | String | No |  |  | Only match incidents for this service. Portal: Owning service. |
| `--owning-team` | List | No |  |  | Space-separated owning team IDs (IcM team IDs are numeric). Portal: Owning team. |
| `--merge-enabled` | Boolean | No |  | `false`, `true` | Merge related incidents into one investigation thread. Service default: true. |
| `--merge-window-hours` | Integer | No |  |  | Hours within which related incidents are merged. Service default: 3. |
| `--max-investigation-attempts`, `--max-attempts` | Integer | No |  |  | How many times the agent automatically investigates a matched incident. Service default: 3. |
| `--alert-id` | String | No |  |  | Only match incidents raised by this alert rule (its resource ID). |
| `--target-resource-type` | String | No |  |  | Only match alerts on this resource type, for example Microsoft.App/containerApps. |
| `--target-resource` | String | No |  |  | Only match alerts on this resource. |
| `--instructions` | String | No |  |  | Custom instructions the subagent follows for matched incidents. |
| `--processing-guide` | List | No |  |  | Quoted step-by-step guidance for the subagent, one value per step. |

**Examples**

- Change the autonomy mode and the merge window

  ```bash
  az sre response-plan update -g myrg --agent-name myagent -n sev1-api \
  --mode autonomous --merge-window-hours 6
  ```
- Point a plan at a different subagent and replace its severities

  ```bash
  az sre response-plan update -g myrg --agent-name myagent -n sev1-api \
  --subagent other-responder --priority Sev0 Sev1
  ```
- Match every severity again and drop the title filter

  ```bash
  az sre response-plan update -g myrg --agent-name myagent -n sev1-api \
  --priority="" --title-contains=""
  ```

## `az sre skill`

Manage custom skills, which are specialized capabilities the agent can use.

Built-in skills are toggled on/off separately, not created here; use 'sre skill create --file-path SKILL.md' to author a custom one, then 'sre skill list'/'sre skill show' to see it.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre skill create --agent-name <value> --resource-group <value> [--name <value>] [--value <value>] [--overwrite {false,true}] [--file-path <value>] [--tools <json-or-@file>] [--description <value>] [--additional-files <json-or-@file>]` |
| `delete` | `az sre skill delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre skill list --name <value> --resource-group <value>` |
| `show` | `az sre skill show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre skill create`

Create or update a custom skill.

**Syntax**

`az sre skill create --agent-name <value> --resource-group <value> [--name <value>] [--value <value>] [--overwrite {false,true}] [--file-path <value>] [--tools <json-or-@file>] [--description <value>] [--additional-files <json-or-@file>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | No |  |  | Name of this instance. |
| `--value` | String | No |  |  | Skill configuration as a JSON document. Alternative to --file-path (specify exactly one of the two). |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |
| `--file-path` | String | No |  |  | Path to a SKILL.md-style file: an optional YAML frontmatter block between '---' lines with name, description and tools, followed by the skill's Markdown instructions. The frontmatter name is used when --name is omitted. Alternative to --value. |
| `--tools` | List | No |  |  | Space-separated tool names this skill can use when active. Only used with --file-path; overrides the SKILL.md frontmatter's 'tools'. Defaults to none. |
| `--description` | String | No |  |  | Skill description. Only used with --file-path; overrides the SKILL.md frontmatter's 'description:' line if both are given. |
| `--additional-files` | List | No |  |  | Other text files the skill uses, such as a reference next to SKILL.md. Repeat --additional-file for each, or list them after --additional-files. They're sent as additionalFiles, named by their path from the SKILL.md folder. Only used with --file-path. |

**Examples**

- Create a skill from a SKILL.md file

  ```bash
  az sre skill create --agent-name myagent --resource-group myrg --name my-skill \
  --file-path SKILL.md --tools kusto-query log-search
  ```
- Name the skill from the SKILL.md frontmatter 'name:' line

  ```bash
  az sre skill create --agent-name myagent --resource-group myrg --file-path SKILL.md
  ```
- Create a skill from a SKILL.md file and a reference file next to it

  ```bash
  az sre skill create --agent-name myagent --resource-group myrg \
  --file-path compliance/SKILL.md --additional-file compliance/detection.md
  ```
- Create a skill from a raw JSON value

  ```bash
  az sre skill create --agent-name myagent --resource-group myrg --name my-skill \
  --value '{"description": "...", "tools": [], "skillContent": "# My skill\n..."}'
  ```

### `az sre skill delete`

Delete a custom skill.

**Syntax**

`az sre skill delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a custom skill

  ```bash
  az sre skill delete -g myrg --agent-name myagent --name triage-skill
  ```

### `az sre skill list`

List custom skills.

**Syntax**

`az sre skill list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's custom skills

  ```bash
  az sre skill list -g myrg --agent-name myagent
  ```

### `az sre skill show`

Show a custom skill.

**Syntax**

`az sre skill show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one custom skill

  ```bash
  az sre skill show -g myrg --agent-name myagent --name triage-skill
  ```

## `az sre subagent`

Manage named sub-agents the meta-agent can hand off work to.

A sub-agent is a scoped specialist with its own instructions, tools, and skills. In the portal, it's the Agent Canvas "Create subagent" dialog.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre subagent create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}] [--pre-tool-use-script-file <value>]` |
| `delete` | `az sre subagent delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre subagent list --name <value> --resource-group <value>` |
| `show` | `az sre subagent show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre subagent create`

Create or update a named sub-agent.

**Syntax**

`az sre subagent create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}] [--pre-tool-use-script-file <value>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Sub-agent configuration as JSON. instructions (at least 50 characters) and handoffDescription are required. Other fields: tools, mcpTools, commonTools, allowedSkills, allowParallelToolCalls. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |
| `--pre-tool-use-script-file`, `--pre-tool-use-script` | String | No |  |  | Path to a script file to run before every tool call this sub-agent makes, like the portal's Manage Hooks > Pre Tool Use button. It's added to --value.hooks.PreToolUse for all tools, with a 30-second timeout and failMode "block". For other matchers or timeouts, set --value.hooks instead. |

**Examples**

- Create a read-only evidence-gathering sub-agent

  ```bash
  az sre subagent create --agent-name myagent --resource-group myrg --name app-investigator \
  --value '{"instructions": "You are the application evidence specialist. Read supplied reference files with ReadFile and return source-backed observations.", "handoffDescription": "Use for read-only application request/error/dependency evidence.", "tools": ["ReadFile"], "mcpTools": [], "commonTools": [], "allowedSkills": ["zava-application-evidence"], "allowParallelToolCalls": true}'
  ```
- Create the same sub-agent with a PreToolUse hook script from a file

  ```bash
  az sre subagent create --agent-name myagent --resource-group myrg --name app-investigator \
  --value "@value.json" --pre-tool-use-script-file readonly-evidence.py
  ```

### `az sre subagent delete`

Delete a sub-agent.

**Syntax**

`az sre subagent delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a sub-agent

  ```bash
  az sre subagent delete -g myrg --agent-name myagent --name app-investigator
  ```

### `az sre subagent list`

List sub-agents.

**Syntax**

`az sre subagent list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's sub-agents

  ```bash
  az sre subagent list -g myrg --agent-name myagent
  ```

### `az sre subagent show`

Show a sub-agent.

**Syntax**

`az sre subagent show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one sub-agent

  ```bash
  az sre subagent show -g myrg --agent-name myagent --name app-investigator
  ```

## `az sre tool`

Manage custom tools the agent can call.

Built-in tools and MCP servers/services are configured separately and are not yet exposed by this CLI.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre tool create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]` |
| `delete` | `az sre tool delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre tool list --name <value> --resource-group <value>` |
| `show` | `az sre tool show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre tool create`

Create a custom tool, or update one with --overwrite.

**Syntax**

`az sre tool create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Tool configuration as JSON. New tools: KustoTool, LinkTool or PythonFunctionTool. PythonTool is a legacy alias for PythonFunctionTool. HttpClientTool is update-only: pass --overwrite for an existing HttpClientTool of the same name. Use PythonFunctionTool or an MCP server for new HTTP integrations. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |

**Examples**

- Create a link tool

  ```bash
  az sre tool create -g myrg --agent-name myagent --name docs-link \
  --value '{"type": "LinkTool", "name": "docs", "description": "Link to docs", "template": "https://learn.microsoft.com/azure/"}'
  ```

### `az sre tool delete`

Delete a custom tool.

**Syntax**

`az sre tool delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a custom tool

  ```bash
  az sre tool delete -g myrg --agent-name myagent --name docs-link
  ```

### `az sre tool list`

List custom tools.

**Syntax**

`az sre tool list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's custom tools

  ```bash
  az sre tool list -g myrg --agent-name myagent
  ```

### `az sre tool show`

Show a custom tool.

**Syntax**

`az sre tool show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one custom tool

  ```bash
  az sre tool show -g myrg --agent-name myagent --name docs-link
  ```

## `az sre usage`

Read an SRE Agent's usage and billing stats.

Token counts and request counts, for a month or broken down by day. Use 'sre usage list' to see how much an agent has used.

| Verb | Exact syntax |
| --- | --- |
| `list` | `az sre usage list --name <value> --resource-group <value> [--daily {false,true}]` |

### `az sre usage list`

List monthly or daily agent-unit usage for an SRE Agent.

**Syntax**

`az sre usage list --name <value> --resource-group <value> [--daily {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent to report usage for. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--daily` | Boolean | No | false | `false`, `true` | Report daily usage (dailyusages) instead of monthly (usages). |

**Examples**

- List this month's usage for an agent

  ```bash
  az sre usage list --agent-name myagent --resource-group myrg
  ```

## `az sre agent settings`

Manage an SRE Agent's global settings (preview).

A single, agent-wide settings object covering tool/skill allow-ask-deny permissions, custom instructions, and approval-expiration behavior.

| Verb | Exact syntax |
| --- | --- |
| `show` | `az sre agent settings show --name <value> --resource-group <value>` |
| `update` | `az sre agent settings update --name <value> --resource-group <value> --value <value>` |

### `az sre agent settings show`

Show an SRE Agent's global settings.

**Syntax**

`az sre agent settings show --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- Show an agent's global settings

  ```bash
  az sre agent settings show --agent-name myagent --resource-group myrg
  ```

### `az sre agent settings update`

Create or update an SRE Agent's global settings.

Always targets the agent's single settings object (there is no --name). Each call replaces the whole object, so include every field you want to keep. Sets the portal's "Custom instructions" box via --value.customInstructions (unrelated to 'sre instructions create').

**Syntax**

`az sre agent settings update --name <value> --resource-group <value> --value <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--value` | String | Yes |  |  | Settings as JSON. Optional fields: customInstructions, toolPermissions, toolStatuses, skillStatuses, approvalExpirationSetting. If you set toolPermissions, include all of allow, ask and deny (use [] if unused). |

**Examples**

- Set the portal's "Custom instructions" text box

  ```bash
  az sre agent settings update -g myrg --agent-name myagent \
  --value '{"customInstructions": "Always cite the runbook section you used."}'
  ```
- Allow, ask for approval, or deny specific tools

  ```bash
  az sre agent settings update -g myrg --agent-name myagent \
  --value '{"toolPermissions": {"allow": ["kusto-query"], "ask": [], "deny": ["run-shell"]}}'
  ```

## `az sre automation http-trigger`

Manage HTTP triggers that run the agent on a webhook call.

Runs the agent against a prompt when an inbound webhook call arrives, instead of on a schedule.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre automation http-trigger create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]` |
| `delete` | `az sre automation http-trigger delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `invoke` | `az sre automation http-trigger invoke --agent-name <value> --resource-group <value> --name <value> [--payload <value>]` |
| `list` | `az sre automation http-trigger list --name <value> --resource-group <value>` |
| `show` | `az sre automation http-trigger show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre automation http-trigger create`

Create or update an HTTP trigger.

**Syntax**

`az sre automation http-trigger create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Trigger configuration as JSON. Fields: agentPrompt, description, agent, threadId, agentMode (readonly, review or autonomous). |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |

**Examples**

- Create a webhook that runs the agent against a prompt

  ```bash
  az sre automation http-trigger create -g myrg --agent-name myagent --name alert-webhook \
  --value '{"agentPrompt": "Investigate the attached alert payload"}'
  ```

### `az sre automation http-trigger delete`

Delete an HTTP trigger.

**Syntax**

`az sre automation http-trigger delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete an HTTP trigger

  ```bash
  az sre automation http-trigger delete -g myrg --agent-name myagent --name alert-webhook
  ```

### `az sre automation http-trigger invoke`

Call an HTTP trigger now, the same way an external webhook would.

Uses your Azure CLI sign-in for the call, so you need data-plane access to the agent. The call goes only to the agent's own endpoint, and redirects aren't followed.

**Syntax**

`az sre automation http-trigger invoke --agent-name <value> --resource-group <value> --name <value> [--payload <value>]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--payload` | String | No |  |  | JSON body to send with the call. The agent sees it alongside the trigger's prompt. |

**Examples**

- Fire a trigger with no payload

  ```bash
  az sre automation http-trigger invoke -g myrg --agent-name myagent --name alert-webhook
  ```
- Fire a trigger with a JSON payload from a file

  ```bash
  az sre automation http-trigger invoke -g myrg --agent-name myagent --name alert-webhook \
  --payload @alert.json
  ```

### `az sre automation http-trigger list`

List HTTP triggers.

**Syntax**

`az sre automation http-trigger list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's HTTP triggers

  ```bash
  az sre automation http-trigger list -g myrg --agent-name myagent
  ```

### `az sre automation http-trigger show`

Show an HTTP trigger.

**Syntax**

`az sre automation http-trigger show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one HTTP trigger

  ```bash
  az sre automation http-trigger show -g myrg --agent-name myagent --name alert-webhook
  ```

## `az sre automation scheduled-task`

Manage scheduled tasks that run the agent on a cron timer.

Runs the agent against a prompt, optionally bounded to a time window or a maximum run count.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre automation scheduled-task create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]` |
| `delete` | `az sre automation scheduled-task delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre automation scheduled-task list --name <value> --resource-group <value>` |
| `pause` | `az sre automation scheduled-task pause --agent-name <value> --resource-group <value> --name <value>` |
| `resume` | `az sre automation scheduled-task resume --agent-name <value> --resource-group <value> --name <value>` |
| `show` | `az sre automation scheduled-task show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre automation scheduled-task create`

Create or update a scheduled task.

Without agentMode, the service runs the task in autonomous mode, even when the agent itself runs in review mode. Set agentMode in --value, for example to "review", so the task's actions wait for approval.

**Syntax**

`az sre automation scheduled-task create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Task configuration as JSON. Fields: cronExpression, agentPrompt, description, agent, threadId, startTime, endTime, maxExecutions, agentMode (readonly, review or autonomous; the service uses autonomous if it's left out), and isEnabled or status (Active or Paused). |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |

**Examples**

- Run the agent on a timer against a prompt, in review mode

  ```bash
  az sre automation scheduled-task create -g myrg --agent-name myagent --name daily-digest \
  --value '{"cronExpression": "0 9 * * 1-5", "agentPrompt": "Summarize overnight alerts", "agentMode": "review"}'
  ```

### `az sre automation scheduled-task delete`

Delete a scheduled task.

**Syntax**

`az sre automation scheduled-task delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Delete a scheduled task

  ```bash
  az sre automation scheduled-task delete -g myrg --agent-name myagent --name daily-digest
  ```

### `az sre automation scheduled-task list`

List scheduled tasks.

**Syntax**

`az sre automation scheduled-task list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's scheduled tasks

  ```bash
  az sre automation scheduled-task list -g myrg --agent-name myagent
  ```

### `az sre automation scheduled-task pause`

Pause a scheduled task so it stops running until resumed.

**Syntax**

`az sre automation scheduled-task pause --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Pause a scheduled task

  ```bash
  az sre automation scheduled-task pause -g myrg --agent-name myagent --name daily-digest
  ```

### `az sre automation scheduled-task resume`

Resume a paused scheduled task.

**Syntax**

`az sre automation scheduled-task resume --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Resume a paused scheduled task

  ```bash
  az sre automation scheduled-task resume -g myrg --agent-name myagent --name daily-digest
  ```

### `az sre automation scheduled-task show`

Show a scheduled task.

**Syntax**

`az sre automation scheduled-task show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one scheduled task

  ```bash
  az sre automation scheduled-task show -g myrg --agent-name myagent --name daily-digest
  ```

## `az sre plugin install`

Install a specific plugin from an already-connected marketplace.

Run 'sre plugin marketplace create' first if you haven't connected a marketplace yet.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre plugin install create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]` |
| `delete` | `az sre plugin install delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre plugin install list --name <value> --resource-group <value>` |
| `show` | `az sre plugin install show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre plugin install create`

Install a plugin from a connected marketplace.

'marketplaceName' and 'pluginName' aren't enough on their own. Also supply the full 'source' block ({"type", "repo", "url"}) with the plugin's exact path in the marketplace repo. This command writes the installation record directly and doesn't run the portal's install pipeline, so unlike a portal install, the result has no 'importedSkills', no 'sourceCommit', and no resolved 'mcpConnectorStatus'.

**Syntax**

`az sre plugin install create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Plugin install configuration as JSON. Requires marketplaceName, pluginName and a "source" block. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |

**Examples**

- Install a plugin from a connected marketplace

  ```bash
  az sre plugin install create -g myrg --agent-name myagent --name datadog \
  --value '{"marketplaceName": "contoso-plugins", "pluginName": "datadog", "source": {"type": "relative", "repo": "contoso/sre-plugins", "url": "plugins/datadog"}}'
  ```

### `az sre plugin install delete`

Uninstall a plugin.

**Syntax**

`az sre plugin install delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Uninstall a plugin

  ```bash
  az sre plugin install delete -g myrg --agent-name myagent --name datadog
  ```

### `az sre plugin install list`

List installed plugins.

**Syntax**

`az sre plugin install list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's installed plugins

  ```bash
  az sre plugin install list -g myrg --agent-name myagent
  ```

### `az sre plugin install show`

Show an installed plugin.

**Syntax**

`az sre plugin install show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one installed plugin

  ```bash
  az sre plugin install show -g myrg --agent-name myagent --name datadog
  ```

## `az sre plugin marketplace`

Connect a repo of plugins as a marketplace the agent can install from.

Supports GitHub, Azure DevOps, and GitLab repos. Use 'sre plugin install' afterward to actually install a plugin from the connected marketplace.

| Verb | Exact syntax |
| --- | --- |
| `create` | `az sre plugin marketplace create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]` |
| `delete` | `az sre plugin marketplace delete --agent-name <value> --resource-group <value> --name <value> [--yes]` |
| `list` | `az sre plugin marketplace list --name <value> --resource-group <value>` |
| `show` | `az sre plugin marketplace show --agent-name <value> --resource-group <value> --name <value>` |

### `az sre plugin marketplace create`

Connect a plugin marketplace.

**Syntax**

`az sre plugin marketplace create --agent-name <value> --resource-group <value> --name <value> --value <value> [--overwrite {false,true}]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--value` | String | Yes |  |  | Marketplace configuration as JSON. Fields: sourceType ("github"), sourceUrl ("owner/repo", not a full URL), owner, description. |
| `--overwrite` | Boolean | No |  | `false`, `true` | Allow replacing an existing one of the same name. Without this flag, creation refuses to overwrite an existing instance. |

**Examples**

- Connect a GitHub repo as a plugin marketplace

  ```bash
  az sre plugin marketplace create -g myrg --agent-name myagent --name contoso-plugins \
  --value '{"sourceType": "github", "sourceUrl": "owner/repo"}'
  ```

### `az sre plugin marketplace delete`

Disconnect a plugin marketplace.

**Syntax**

`az sre plugin marketplace delete --agent-name <value> --resource-group <value> --name <value> [--yes]`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |
| `--yes`, `-y` | Flag | No | false |  | Do not prompt for confirmation. |

**Examples**

- Disconnect a plugin marketplace

  ```bash
  az sre plugin marketplace delete -g myrg --agent-name myagent --name contoso-plugins
  ```

### `az sre plugin marketplace list`

List connected plugin marketplaces.

**Syntax**

`az sre plugin marketplace list --name <value> --resource-group <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `-n`, `--name`, `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |

**Examples**

- List an agent's connected plugin marketplaces

  ```bash
  az sre plugin marketplace list -g myrg --agent-name myagent
  ```

### `az sre plugin marketplace show`

Show a connected plugin marketplace.

**Syntax**

`az sre plugin marketplace show --agent-name <value> --resource-group <value> --name <value>`

| Option / aliases | Type | Required | Default | Allowed values | Description |
| --- | --- | --- | --- | --- | --- |
| `--agent-name` | String | Yes |  |  | Name of the SRE Agent. |
| `--resource-group`, `-g` | String | Yes |  |  | Name of resource group. You can configure the default group using `az configure --defaults group=<name>` |
| `--name`, `-n`, `--extension-name` | String | Yes |  |  | Name of this instance. |

**Examples**

- Show one connected plugin marketplace

  ```bash
  az sre plugin marketplace show -g myrg --agent-name myagent --name contoso-plugins
  ```
