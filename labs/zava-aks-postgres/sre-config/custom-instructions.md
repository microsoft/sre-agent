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

For a broad or ambiguous incident with independent evidence paths, launch one
parallel subagent per path (usually two), state each scope clearly, and run them
concurrently. Wait for all results, verify material claims, then synthesize the
evidence before selecting a root cause or remediation. Keep dependent steps
sequential and do not parallelize write or remediation work.
