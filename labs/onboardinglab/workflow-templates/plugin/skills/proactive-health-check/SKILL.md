---
name: proactive-health-check
description: Assess ticket reservation availability, failures, latency, dependencies, and Azure resource health using read-only evidence.
---

# Proactive health check

Use the connected application telemetry and read-only Azure tools to assess the ticket reservation service.

1. Confirm the UTC analysis window and the Application Insights resource being queried.
2. Measure ticket reservation request volume, availability, failure rate, and latency over the last 24 hours.
3. Discover the selected option from the managed resource group's `onboardingLabWorkloadOption` tag. Review App Service resource health and configuration signals. For `app-service-postgresql`, also review PostgreSQL dependency outcomes and relevant database and network state.
4. Compare with the prior seven-day baseline only when sufficient history exists. State when the environment is too new for a meaningful baseline.
5. Use `PlotAreaChartWithCorrelation` to display meaningful 24-hour availability, failure-rate, latency, or dependency time series. Use `PlotBarChart` only for a valid current-versus-baseline or bounded dependency comparison. Label charts with UTC windows, units, and series. Do not plot empty, invented, or misleadingly sparse values; use a short table instead.
6. Separate confirmed findings from hypotheses and identify missing or contradictory evidence.
7. Return evidence links, relevant charts, risks, and recommended follow-up in the current thread.

Do not modify Azure resources, create issues, update memory, or create or update a Live Report. Send email only when the invoking scheduled-task prompt supplies the trusted recipient and explicitly requests one Review-gated health summary. Do not add recipients or blindly retry an unknown send outcome. If severe customer impact is active, provide an escalation draft for human review only.