---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: plot-incident-metrics
description: |
  Produce ONE consolidated multi-series chart capturing all incident-relevant
  metrics for a service, then upload it to the ServiceNow incident.
  Use this skill any time an agent needs to visualize an incident — never
  generate multiple separate charts per incident.
---

# Plot Incident Metrics

## Overview
This skill is the **single, canonical way** for any SRE Agent to produce
incident charts. It enforces a **one-chart-per-incident** rule: all
related metrics are overlaid on the same time axis so the responder sees
correlation at a glance, instead of context-switching across multiple
images.

## Hard rule — ONE chart per incident
- ❌ Do **NOT** call the plotting primitives multiple times per incident
- ❌ Do **NOT** upload more than one chart attachment per SNOW INC
- ✅ Always pass the FULL metric set (below) to a single chart call
- ✅ If a metric is unavailable, omit just that series — still emit one chart

## Required series (all overlaid, shared time axis)
| # | Series                | Source                   | Notes                                |
|---|-----------------------|--------------------------|--------------------------------------|
| 1 | Request rate          | App Insights `requests`  | requests/sec, bin 1m                 |
| 2 | Error rate (5xx %)    | App Insights `requests`  | `countif(success==false)/count()*100`|
| 3 | P95 latency (ms)      | App Insights `requests`  | `percentile(duration,95)`            |
| 4 | CPU utilization (%)   | ACA / Azure Monitor      | `UsageNanoCores / cpuLimit * 100`    |
| 5 | Memory utilization (%)| ACA / Azure Monitor      | `WorkingSetBytes / memoryLimit * 100`|
| 6 | Request queue depth   | ACA ingress metrics      | `Requests` queue / pending           |
| 7 | Replica count         | ACA scale metrics        | `Replicas` count                     |

## Required annotations on the chart
- **Vertical line** at the deploy timestamp (label: `Deploy <buildId>`)
- **Vertical line** at the incident detection timestamp (label: `Incident detected`)
- Time window: **30 min before deploy → now** (or +60 min, whichever is shorter)

## Tools used
- `PlotAreaChartWithCorrelation` (preferred — handles multi-series overlay
  and correlation visualization natively) **OR**
  `PlotTimeSeriesData` (fallback — one call, multiple series)
- `UploadChartToServiceNow` — exactly **one** invocation, immediately after
  the plotting call

## Standard KQL (App Insights side, for series 1–3)
Use a single union/join query that produces one timeseries per metric:

```kusto
let svc = "<service-name>";
let deployTime = datetime(<ISO8601>);
let window = totimespan(90m);
requests
| where cloud_RoleName == svc
| where timestamp between (deployTime - 30m .. deployTime + window)
| summarize
    request_rate   = count() / 60.0,
    error_rate_pct = 100.0 * countif(success == false) / count(),
    p95_latency_ms = percentile(duration, 95)
  by bin(timestamp, 1m)
| order by timestamp asc
```

For series 4–7, query Azure Monitor on the Container App resource for
`UsageNanoCores`, `WorkingSetBytes`, `Requests`, `Replicas` over the
same time range. Pass all results into the single chart call.

## Workflow
1. **Determine context:** the calling agent provides:
   - `service` — e.g. `outage-api`
   - `inc_number` — e.g. `INC0010042`
   - `deploy_time` — ISO 8601, optional (omit annotation if unknown)
   - `incident_time` — ISO 8601, when the issue was detected
2. **Build the multi-series dataset** (KQL above + Azure Monitor queries)
3. **Call the plotting tool ONCE** with all 7 series + annotations
4. **Call `UploadChartToServiceNow` ONCE** with the resulting base64 PNG,
   filename `incident-overview-<inc_number>.png`
5. **Add a SNOW work note** linking the attachment and listing the
   metrics included (so reviewers know what's in the chart)

## Constraints
- Do not chart unrelated services in the same image — one chart per
  affected service if multiple services are involved
- Do not lower the time resolution below 1-min bins (loses signal)
- Do not crop the time window to exclude the deploy — the deploy
  timestamp is the most important reference point
- If chart generation fails twice in a row, fall back to a SNOW work
  note that links the raw KQL query instead of looping further

## Example invocation context
> "outage-api started returning 500s 4 minutes after the v2027.04.17.1
> deploy. Use plot-incident-metrics with service=outage-api,
> inc_number=INC0010042, deploy_time=2026-04-17T22:30:00Z,
> incident_time=2026-04-17T22:34:12Z."

The skill produces **one** PNG attached to INC0010042 showing all 7
series with both vertical reference lines, and the agent moves on to
remediation — no further charting needed.

## Related
- `deployment-validator` — primary consumer (Phase A visualization)
- `incident-handler` — consumer (PHASE 5 visualization, replaces
  ad-hoc charting)
- `servicenow-incident-mgmt` — for the SNOW INC the chart attaches to
