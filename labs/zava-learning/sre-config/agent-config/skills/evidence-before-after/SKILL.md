---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: evidence-before-after
description: Use to build the before-and-after visual evidence for a Zava Learning incident. First classify the fault, then render the ONE visual that actually explains what changed — a before/after path or topology diagram for connectivity/config/RBAC faults, or time-series comparison charts for performance/availability faults — plus a state/metric delta table. Never plot a metric that does not tell the story. Its output is used in the RCA and the zava-reporting deliverables.
tools:
  - RunAzCliReadCommands
  - GetAzCliHelp
  - ListAvailableMetrics
  - GetMetricTimeSeriesElementsForAzureResource
  - QueryAppInsightsByResourceId
  - QueryLogAnalyticsByResourceId
  - PlotBarChart
  - PlotAreaChartWithCorrelation
  - PlotScatter
  - ExecutePythonCode
  - SearchMemory
---

## Zava Learning — Before / After Evidence

Prove impact and recovery with the *right* visual for the fault — not a chart by reflex. Resource
Group: `@@RG@@`. Services: `learner-portal`, `course-api`, `assessment-api`. Retrieve `zava-brand`
and `zava-report-template` with `SearchMemory` and apply the house style. Use the windows and
root cause confirmed by `rca-analysis`.

## Step 1 — Decide the visual FIRST (do not skip)
Classify what actually changed, then pick the visual that explains *that*. Plotting a smooth metric
for a binary/config fault (e.g. "availability before/after" for an NSG block) is misleading and
adds no insight — don't do it.

| Fault class | What changed | Primary visual | Secondary (only if telemetry shows it) |
|---|---|---|---|
| **Connectivity / config / NSG / App Gateway probe / RBAC** | a path or permission was **closed → open** (binary) | **before→after path/topology diagram (ASCII or Mermaid)** + a config-state delta table | one short recovery curve (e.g. 502-rate → 0) |
| **Performance / latency / saturation** | a metric **degraded → recovered** (gradual) | **time-series before/during/after** + percentile delta table | before-vs-after summary bars |
| **Availability / reliability** (5xx, restarts, replica loss) | error/health rate **rose → fell** | **time-series** + delta table | summary bars |

If a fault has both a binary cause and a metric symptom (common), lead with the **diagram** that
explains the cause and use **one** metric chart only as supporting recovery proof.

## Step 2 — Capture the before/after STATE (config & binary faults)
For connectivity/config/RBAC faults, the evidence is the changed configuration, not a metric:
- Read the relevant config with `RunAzCliReadCommands` (e.g. NSG effective rules, App Gateway
  backend health, Container Apps revision/ingress, role assignments) at the mitigated state, and
  reconstruct the pre-fix state from `rca-analysis` / change history.
- Build a **state delta table**: `item · before · after · effect`, e.g.
  `NSG rule block-appgw (prio 100 DENY) · present · removed · AppGW→apps unblocked`;
  `AppGW backend health · Unhealthy · Healthy · probes pass`; `GET /api/quiz · 502 · 200`.
- Render a **before→after path diagram** showing the broken hop and the fixed hop. Author it as
  ASCII (preferred for chat/PagerDuty notes) and/or a Mermaid graph; for a polished report image
  use `ExecutePythonCode` (graphviz/matplotlib). Example shape:

  ```
  BEFORE (blocked)                         AFTER (fixed)
  AppGW ──►  NSG subnet  ──► [apis]         AppGW ──►  NSG subnet  ──► [apis]
                │ DENY-100 ✗                              │ (rule removed) ✓
  backend: UNHEALTHY (502)                 backend: HEALTHY (200)
  ```

## Step 3 — Pull metrics (performance/availability faults, or as recovery proof)
Only when a metric genuinely tells the story. Define three windows — **Before** (healthy baseline),
**During** (detection→mitigation), **After** (post-fix, long enough to be credible) — using the
exact windows from `rca-analysis`. Per affected service pull the metric matching the symptom:
- Availability / HTTP 5xx / success rate (`QueryAppInsightsByResourceId`).
- Latency — for the latency scenario, `ms=<duration>` from assessment-api console logs via
  `QueryLogAnalyticsByResourceId`; report p50/p95/p99.
- Replica count / restarts / throughput (`ListAvailableMetrics`,
  `GetMetricTimeSeriesElementsForAzureResource`).

Render brand-colored: before series in Critical red, after in Zava Teal, target/baseline as a
dashed Slate line, every series labeled; annotate mitigation and fix points.
`PlotAreaChartWithCorrelation` / `PlotScatter` for the series, `PlotBarChart` for before-vs-after
bars. Use `ExecutePythonCode` (matplotlib) only for a comparison the Plot* tools can't express.

## Rules
- One headline visual that explains the cause; supporting visuals only if the data backs them.
- Never plot a metric that doesn't change shape across the fault, or fabricate a trend to fill a slide.
- Same units, axes, and aggregation before vs. after — no misleading scales.
- Don't claim recovery a number doesn't support; if the after-window is too short, say so.

## Verification
The visual matches the fault class: a before/after diagram + state delta table for config/binary
faults, or a before/after chart + metric delta table for performance/availability faults — all from
real config/telemetry over clearly stated windows, ready for `rca-analysis` and `zava-reporting`.
