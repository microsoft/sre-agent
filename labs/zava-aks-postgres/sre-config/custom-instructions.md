## Incident correlation

When an alert may overlap with another condition, use the `incident-correlation`
skill to review nearby fired alerts, relevant disabled rules, and Azure Service
Health.

Treat timing as a candidate relationship, not proof of causation. Confirm a shared
mechanism in telemetry before assigning a common root cause. Report independent
causes separately and leave remediation for an acknowledged alert to its existing
investigation.

If the available evidence supports a single isolated incident, proceed without an
extended correlation sweep.

## Parallel investigation

For overlapping application and database symptoms or conflicting evidence, read
`zava-investigation-coordination`. Prefer the configured evidence specialists when
their capabilities fit: usually two independent read-only paths, run concurrently.
Wait for all results and verify sources before synthesis. Handle simple checks
directly, preserve incident ownership, and do not confuse agreement with causation.
Keep dependent steps sequential and never parallelize remediation.

If a tool or policy blocks a remediation action, report the blocked step.
Do not route around the restriction with another tool or a broader configuration
change. Continue only with separately authorized actions.
