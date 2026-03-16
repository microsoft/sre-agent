# GitHub Issue Formatting — Incident Report Template

When creating a GitHub issue for an incident, use the following structured format. This ensures consistency, readability, and actionable write-ups.

---

## Issue Title Format

```
Incident: <short description> (<affected service>)
```

**Example:** `Incident: HTTP 5xx due to OutOfMemory in Cart API (Grubify Container App)`

---

## Issue Body Template

Use this exact markdown structure for the issue body:

````markdown
# Incident Report: <short description>

- **Incident ID:** `<incident-id or alert correlation ID>`
- **Service:** Azure Container Apps — `<container-app-name>` (rg: `<resource-group>`)
- **Subscription:** `<subscription-id>`
- **FQDN:** `<app-fqdn>`
- **Active revision:** `<revision-name>` (100% traffic)

## Summary

<2-3 sentences describing what happened, what error was observed, and the symptoms.>

## Impact

- <User-facing impact, e.g., "API errors (5xx) on Cart endpoint during the spike window">
- <Secondary impacts, e.g., "Failed cart operations for affected users">

## Timeline (UTC)

- **~HH:MM:** <First sign / metric anomaly>
- **~HH:MM:** <Error escalation or alert fired>
- **~HH:MM:** <Peak or notable event>

## Evidence

### Console logs (active revision)

```
<paste relevant error logs, stack traces>
```

### Traffic and Response Time

<Use ExecutePythonCode to generate a chart of request count and response time over the investigation window. Attach the chart image.>

### Metrics snapshot (Azure Monitor)

- **Requests** (5m bins): <values at key timestamps>
- **ResponseTime avg:** <peak value>
- **RestartCount:** <value>
- **MemoryPercentage:** <value and interpretation>
- **UsageNanoCores:** <value if relevant>

## Root Cause

<1-2 sentences explaining the technical root cause. Reference the specific code path, controller, or component.>

## Remediation

- **Code:** <code-level fix, e.g., "Implement bounded cache or move to persistent store">
- **Defensive:** <validation/throttling, e.g., "Add payload size limits and rate limiting">
- **Platform:** <infrastructure fix, e.g., "Increase memory limit, add memory-based autoscale">
- **Observability:** <monitoring improvements, e.g., "Add alert for OOM exceptions">

## Action Items

| # | Action | Priority |
|---|--------|----------|
| 1 | <specific fix> | High |
| 2 | <test to add> | Medium |
| 3 | <config change> | Medium |
| 4 | <monitoring improvement> | Low |

## References

- Container App: `<full ARM resource ID>`
- Log Analytics Workspace ID: `<workspace GUID>`
- App Insights: `<full ARM resource ID>`
````

---

## Labels to Apply

Based on classification, apply these labels to the GitHub issue:

| Condition | Labels |
|-----------|--------|
| Any bug | `bug` |
| API-related | `api-bug` |
| Frontend-related | `frontend-bug` |
| Memory leak / OOM | `memory-leak` |
| Critical or high severity | `severity-high` |
| Medium severity | `severity-medium` |
| Performance degradation | `performance` |

---

## Charts and Visual Evidence

When generating evidence, use `ExecutePythonCode` to create charts:
- Plot **Requests** and **ResponseTime** over time (dual-axis line chart)
- Plot **MemoryPercentage** or **WorkingSetBytes** if memory-related
- Use clear titles, axis labels, and timestamps in UTC
- Save charts as PNG and attach to the issue

---

## Tips for Quality Incident Reports

1. **Be specific** — include actual metric values, timestamps, and resource IDs
2. **Include stack traces** — paste the full exception with file:line references
3. **Show before/after** — compare the anomaly window to the normal baseline
4. **Actionable items** — every report must end with concrete next steps
5. **Link resources** — include full ARM resource IDs for quick portal navigation
