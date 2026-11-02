# Live Report build guide

Build an Azure SRE Agent operational report with Container Apps inventory, application logs, Application Gateway metrics, a configured topology, and an optional operator-triggered investigation action.

This is an authoring guide, not a deployed report or a guarantee of API compatibility. Discover the tools, schemas, security requirements, and supported libraries in your own agent before building. The validation checklist below describes checks you must perform; this guide does not claim end-to-end report validation.

For a simpler read-only report, see the [onboarding lab's Live Report walkthrough](../labs/onboardinglab/README.md#scenario-2-scheduled-health-check-and-live-report). Use the [Azure SRE Agent documentation](https://aka.ms/sreagent/newdocs) and the authoring references available in your agent as the source of truth.

## 1. Discover prerequisites

### Authoring references and connector tools

In the SRE Agent authoring conversation, load the `live_report_authoring` skill and its `security-and-csp`, `libraries`, and `runtime-api` references, if available. Read the complete relevant sections, not truncated excerpts. If the skill or an equivalent current authoring reference is unavailable, stop and establish the supported authoring workflow before proceeding.

Run `ListConnectors`, then `ListConnectorTools` for each selected connector. Report runtime calls must use connector tools exposed by discovery and authorized in the report's `allowedTools`. Tools available in agent chat are not necessarily available to the report: do not substitute built-in tools such as `RunAzCliReadCommands`, `QueryLogAnalyticsByResourceId`, or `QueryAppInsightsByResourceId`.

The following names are examples, not required connector names or a guaranteed tool catalog:

| Capability | Example connector tool | Discover and verify |
|---|---|---|
| Container Apps inventory | `azure-mcp_azure` | `containerapps` / `containerapps_list`, scope parameters, and returned resource fields |
| Workspace log queries | `system-mcp-monitor_monitor_workspace_log_query` | Workspace identifier format, KQL schema, time range, and result limits |
| Gateway host metrics | `system-mcp-monitor_monitor_metrics_query` | Resource identifier, metric names, dimensions, aggregation, interval, and bucket limits |
| Optional investigation creation | `azure-mcp_azure` | `sreagent` / `sreagent_threads_create`, required parameters, permissions, and response schema |

Where the Azure connector supports `learn: true`, use it to discover top-level tools and then the `sreagent` commands. Do not infer support from a connector version. If thread creation is unavailable or not authorized, omit the launch action and provide a copyable investigation prompt.

Probe each required **read** call once with a narrow resource scope, explicit time bounds where supported, and a small result limit. Discover which application tables and columns exist; `ContainerAppConsoleLogs_CL` and `Syslog` are examples, not universal schemas. Do not create a test investigation thread during discovery.

### Permissions and identity

Identify the principal used by each connector and verify its effective permissions at the narrowest required scope. The roles below are starting points to evaluate, **not verified assignments or a complete RBAC prescription**:

| Operation | Permission guidance to verify |
|---|---|
| Inventory and metrics reads | Evaluate Reader on the relevant resource or application resource group; verify the required read operations |
| Application log queries | Evaluate Log Analytics Reader on the application workspace, accounting for workspace access mode and any table-level controls |
| Investigation creation | Verify the specific thread-creation authorization on the target agent; do not grant broad Contributor access as a shortcut |

Azure permissions, connector authorization, report tool approval, and agent tool policies are separate controls. Review all of them. A multiplexed connector may expose both reads and writes through one tool name; an `allowedTools` entry alone is not proof of read-only access.

Thread attribution may reflect the connector identity rather than the person clicking the button. Verify the identity and audit behavior in your environment; do not assume the operator's identity is delegated. Starting an investigation can also cause downstream agent actions under its existing policies. Retain required review gates.

### Environment values

Replace these placeholders privately when authoring your report. Do not publish the populated configuration, credentials, or sensitive query results.

| Placeholder | Value to supply |
|---|---|
| `<REPORT_NAME>` | A report name you own and intend to create or update |
| `<SUBSCRIPTION_ID>` | Target workload subscription |
| `<APP_RESOURCE_GROUP>` | Workload resource group |
| `<APP_WORKSPACE>` | Application Log Analytics workspace identifier in the discovered tool's required format, not automatically the agent's own workspace |
| `<GATEWAY_RESOURCE_ID>` | Full resource ID of the Application Gateway to query |
| `<AGENT_SUBSCRIPTION_ID>` | Target agent subscription, which may differ from the workload subscription |
| `<AGENT_RESOURCE_GROUP>` | Target agent resource group |
| `<AGENT_NAME>` | Target agent name |
| `<CONFIGURED_TOPOLOGY>` | Reviewed application nodes and edges from your configuration, with their source identified |

## 2. Handle runtime data safely

Build adapters from the actual read-call responses. For example, a connector may return a text envelope containing JSON:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"results\":{\"containerApps\":[]}}"
    }
  ],
  "isError": false
}
```

Other possible shapes include `{ "status": 200, "results": [] }` for logs, or nested metric results with `timeSeries` and `avgBuckets`. These are illustrative shapes, not API contracts. Inspect all relevant content blocks rather than blindly parsing `content[0].text`. Check transport/runtime errors, `isError`, embedded status values, and required fields before treating a response as usable data. Surface parse failures and unsupported shapes as errors, not empty success.

Keep source timestamps, query scope, dimensions, and aggregation visible. Handle null buckets and missing telemetry as unknown; do not coerce them to zero. Count error logs separately from a recent-log table that includes all levels.

For every refresh, capture one UTC end time and derive the start time from the selected window. Pass explicit `start-time` and `end-time` where those parameters are supported. The following are candidate settings to validate against the discovered metrics schema, dimension count, and bucket limits:

| Window | Example interval | Example `max-buckets` |
|---|---|---|
| 1 hour | `PT5M` | 15 |
| 6 hours | `PT15M` | 30 |
| 24 hours | `PT1H` | 48 |

Apply the same window to log queries. Bound rows and response sizes, prevent overlapping refreshes from replacing newer data, and expose partial failures without hiding successful panels. A provisioning inventory is a current snapshot, not historical state for the selected window.

## 3. Construction prompt

Replace the placeholders, review the scope, and paste this prompt into your SRE Agent authoring conversation. Tool names below must be reconciled with discovery before saving.

```text
Build a Live Report named "<REPORT_NAME>" for the following scope:
workload subscription <SUBSCRIPTION_ID>, resource group <APP_RESOURCE_GROUP>,
application workspace <APP_WORKSPACE>, gateway <GATEWAY_RESOURCE_ID>;
target agent <AGENT_NAME> in subscription <AGENT_SUBSCRIPTION_ID> and
resource group <AGENT_RESOURCE_GROUP>.
Configured topology: <CONFIGURED_TOPOLOGY>.

First run ListReports. If exactly one intended report has this name, read it
with GetReport and update it using its reportId. If none exists, create it.
If the match is ambiguous, stop for clarification. Leave other reports alone.

DISCOVERY
Load the current live_report_authoring skill and its complete security-and-csp,
libraries, and runtime-api references. If unavailable, stop rather than guess.
ListConnectors and ListConnectorTools; use only discovered connector tools.
Discover inventory, workspace logs, and gateway metrics schemas and perform
bounded read probes. Discover thread creation without invoking it.
Verify the scope and principal used by each connector. Report missing
permissions explicitly; do not silently broaden access.

LAYOUT
Use a readable dark theme, restrained severity colors with text labels, and
only supported fonts/libraries. Include scope, a 1h/6h/24h selector, Refresh,
last successful update time, and a shared resource inspector.
Tabs: Operations, Configured Topology, and Resource Explorer.

OPERATIONS
Show symptom-only Needs Attention items: a known non-Succeeded provisioning
state, latest available UnhealthyHostCount bucket above zero, or more than
10 error log lines in the selected window. Treat the log threshold as an
example heuristic, not an SLO or root cause. Include relevant Syslog failure
signals only after discovering and scoping the application's schema.
Show missing, stale, or failed data sources as unknown/warning, never healthy.
Use "Provisioning and log signals" for the app grid, not "Service Health".
Show resource names and environment labels from inventory.
Chart HealthyHostCount and UnhealthyHostCount with dimensions, aggregation,
and timestamps; do not translate aggregates into an inferred pool count.
Show the latest 50 scoped container logs at all levels, separately from the
error count. Keep logs safe for the report audience.

CONFIGURED TOPOLOGY AND RESOURCE EXPLORER
Render only the supplied nodes and edges, labeled "Configured topology;
not discovered dependencies or observed traffic". Enable node inspection.
Distinguish live inventory from manually configured entries. Do not invent
missing resources, listeners, backend pools, or relationships.

INVESTIGATE (OPTIONAL WRITE)
Provide an editable prompt with symptoms, resource scope, evidence timestamps,
and the selected window. Explain that launch creates a real agent thread.
Enable launch only when the discovered thread command is supported and
authorized. Keep a copyable prompt fallback.
Invoke thread creation only after an intentional operator click and any
required approval, never on load, refresh, selection, or automatic retries.
Disable launch while pending. Retain the returned thread reference and link
so repeated clicks do not accidentally launch another investigation.
For a timeout with an unknown outcome, explain that a thread may exist and
require the operator to check before trying again.
Render the first reply only if supplied by the verified response contract.

SECURITY AND RUNTIME
Follow the current authoring reference's CSP exactly. Use the required
nonce="{REPORT_NONCE}" on inline scripts and styles where specified.
Do not use inline event attributes; attach listeners with addEventListener
inside the authorized script after the DOM is ready.
Use only approved library tags and their complete verified SRI hashes.
Never invent a hash or relax CSP to make a library load.
Render tool data, logs, prompts, and replies with textContent, not innerHTML.
Validate navigation URLs against the trusted portal origin and expected route;
encode dynamic path segments. Do not navigate to arbitrary tool-returned URLs.
Do not embed credentials or make direct cloud API calls to bypass connectors.
Give every panel loading, empty, partial/stale, and error states. Catch and
display tool failures with useful recovery steps, without leaking secrets.
Bound log and metric calls to the selected UTC window and supported limits.

SAVE AND HANDOFF
Write HTML to the temporary location required by the authoring workflow.
SaveReport using only discovered connector tool names actually needed in
allowedTools. If using a multiplexed tool, explain its required commands and
review the relevant command permissions; its name alone is not a read-only
boundary. Request normal connector/tool approval; never bypass policy.
Report what was actually verified and what remains to be checked in the UI.
Do not claim successful runtime behavior just because the report saved.
```

### Investigation adapter notes

If discovery confirms the example Azure MCP command, its inputs may resemble `tool: "sreagent"`, `command: "sreagent_threads_create"`, with `parameters` containing `message`, `agent`, `subscription`, and `resource-group`. Use the **agent** scope for those parameters, not automatically the workload scope. Validate the actual schema before implementation.

A response may contain `results.threadId`; do not assume it always does or that a first reply is present. Prefer a documented navigation mechanism. If constructing a portal link, confirm the current route first. An illustrative route is:

```text
https://sre.azure.com/agents/subscriptions/<AGENT_SUBSCRIPTION_ID>/resourceGroups/<AGENT_RESOURCE_GROUP>/providers/Microsoft.App/agents/<AGENT_NAME>/views/thread/<THREAD_ID>
```

`<THREAD_ID>` must come from a validated successful response. Validate the origin and expected route, encode path segments, and use `rel="noopener noreferrer"` when opening a new tab. A stateless model response is not evidence that an investigation thread was created.

## 4. Troubleshooting

| Symptom | What to check |
|---|---|
| Save rejects an unknown connector tool | Rediscover `ListConnectorTools`, remove built-in chat-only tools, and reconcile `allowedTools` with the actual runtime calls |
| Tabs, refresh, or filters do nothing | Inspect CSP errors; replace inline event handlers with listeners in the authorized script |
| Metrics fail with a bucket-limit error | Verify explicit time bounds, interval, dimensions, and the tool's bucket limit; do not let a default window override the selector |
| Logs are empty | Distinguish query errors from zero rows; check workspace, ingestion, schema, scope, and time range before changing filters |
| A chart or topology fails to render | Inspect library-load and CSP errors; re-read approved tags and verify SRI rather than disabling security checks |
| Investigation launch is unavailable or fails | Check command discovery, target agent scope, effective permissions, and report approval; keep the copyable prompt available |
| A launch times out | Treat the write outcome as unknown; check for an existing thread before an intentional retry |

## 5. Reader validation checklist

- [ ] Confirm effective permissions and connector identity; review report tool approvals and agent policies.
- [ ] Confirm only intended resources and application telemetry are queried; redact sensitive log content for the report audience.
- [ ] Open the saved report and exercise every tab, inspector, filter, and refresh control.
- [ ] Test 1h, 6h, and 24h windows; inspect request bounds and chart timestamps, dimensions, aggregation, and bucket counts.
- [ ] Check loading, empty, stale, missing-data, parse-error, and permission-error behavior. Unknown must never appear healthy.
- [ ] Verify library loading, complete SRI hashes, CSP, and safe rendering of text containing markup characters.
- [ ] Check keyboard navigation, readable state labels, and the layout at desktop and approximately 390px mobile width.
- [ ] Verify that loading and refreshing cause no thread creation or other automatic writes.
- [ ] Only with explicit approval, launch one real investigation; verify attribution, duplicate-click handling, reply rendering if available, and that the link opens the intended thread.
- [ ] Confirm the saved report's identity and that no unrelated report was changed.

## 6. Sample limitations

This design combines provisioning state, log-volume heuristics, and selected gateway metrics. Successful provisioning and few error logs do **not** establish request availability, latency, dependency health, or an SLO result. Display "No configured attention signal" rather than an unqualified "Healthy" state when the available checks find nothing.

Configured topology is not dependency discovery. Static Resource Explorer entries are not live resource inventory. Gateway metric aggregates are not a count of healthy backend pools; interpret the actual series and dimensions rather than inventing a denominator.

The prompt does not implement per-pool backend health, NSG analysis, Application Insights request health, PostgreSQL or VM health, notification delivery, or a watchlist. A UI-level launch guard is not server-side idempotency and may not prevent duplicates across sessions. None of these capabilities should be implied by labels or empty panels.

Saving a report does not configure a recurring health-check task. Follow the separate [onboarding workflow](../labs/onboardinglab/README.md#scenario-2-scheduled-health-check-and-live-report) if that is needed.
