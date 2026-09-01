## Incident correlation runbook (Zava)

Resource Group `@@RG@@`.

Use this read-only skill when an investigation needs context beyond its initial
alert. This sample opens each alert in a separate thread, so review nearby signals
before assigning a shared cause.

## 1. Review fired alerts

Use the Alerts Management REST API:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d&pageCount=250" --query "value[].{ruleId:properties.essentials.alertRule, rg:properties.essentials.targetResourceGroup, sev:properties.essentials.severity, cond:properties.essentials.monitorCondition, start:properties.essentials.startDateTime, target:properties.essentials.targetResource}" -o json`

- `pageCount` must be 1..250. `timeRange` accepts 1h, 1d, 7d, or 30d.
- `RunAzCliReadCommands` rejects shell pipes and `&&` — issue one command per call.
- For log alerts, use `rg` and `ruleId` to identify the environment because
  `targetResource` can be the Log Analytics workspace.

## 2. Review relevant alert rules

Inventory enabled and disabled rules separately from fired-alert history:

`az monitor metrics alert list -g @@RG@@ --query "[].{name:name, enabled:enabled, scopes:scopes}" -o json`
`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/microsoft.insights/scheduledQueryRules?api-version=2023-03-15-preview" --query "value[].{name:name, enabled:properties.enabled, window:properties.windowSize, freq:properties.evaluationFrequency}" -o json`

If a relevant rule is disabled, query its underlying metric directly. This sample
includes a disabled `Zava-db-cpu-saturation` rule for that demonstration.

## 3. Check Azure Service Health

Query subscription-scoped events for service issues, planned maintenance, and
health advisories:

`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&queryStartTime=<ISO8601>" --query "value[].{type:properties.eventType, level:properties.eventLevel, status:properties.status, title:properties.title, start:properties.impactStartTime}" -o json`

Per-resource availability:
`az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/@@RG@@/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview" --query "value[].{res:id, avail:properties.availabilityState, summary:properties.summary}" -o json`

## 4. Confirm the mechanism

Filter every App Insights query by `AppRoleName == 'zava-api'`; the workspace also contains the agent's own ARM-poll telemetry.

Alert timestamps show overlap but do not establish causal order. Use raw telemetry
in 1-2 minute buckets to compare onset.

Before assigning a shared cause, confirm a common mechanism:

| Observation | Reading |
|---|---|
| HTTP 500, failed dependencies ONLY on `localhost:3001`, zero PG dependency failures | app-layer regression |
| HTTP 503, failed dependencies against the PG target | DB unreachable |
| No dependency failures but PG `cpu_percent` and latency are high | DB saturation with successful slow queries |

Split dependency telemetry by `target` and `resultCode`. If the mechanisms differ,
report the conditions as independent.

Treat alerts from another resource group as a separate Zava environment. Cross-resource
group timing can justify a Service Health check but is not sufficient for correlation.

## 5. Report

State whether the evidence supports one cause across several alerts, independent
causes, or an isolated alert. If an independent alert is already acknowledged,
include the relationship in the report and leave remediation to its existing thread.

## Boundaries
Read-only. Use the relevant domain skill for remediation.
