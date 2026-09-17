---
name: proactive-health-check
description: Assess ticket reservation availability, failures, latency, dependencies, and Azure resource health using read-only evidence.
---

# Proactive health check

Use the connected application telemetry and read-only Azure tools to assess the ticket reservation service.

1. Confirm the UTC analysis window and the Application Insights resource being queried.
2. Measure ticket reservation request volume, availability, failure rate, and latency over the last 24 hours.
3. Review PostgreSQL dependency outcomes and relevant Azure resource health or configuration signals.
4. Compare with the prior seven-day baseline only when sufficient history exists. State when the environment is too new for a meaningful baseline.
5. Separate confirmed findings from hypotheses and identify missing or contradictory evidence.
6. Return evidence links, risks, and recommended follow-up in the current thread.

Do not modify Azure resources, create issues, send email, update memory, or create or update a Live Report. If severe customer impact is active, provide an escalation draft for human review only.