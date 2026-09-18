# Onboarding Lab Database Connectivity Runbook

## Scope

Use this runbook when ticket reservations return HTTP 503 or the `POST /checkout` dependency to PostgreSQL fails. Establish the affected UTC interval before querying evidence.

## Read-only investigation

1. Query the configured `app-insights` connector for `POST /checkout` request count, failure count, status, and duration during the affected interval.
2. Correlate failed requests with PostgreSQL dependency failures. A healthy `GET /healthz` response does not prove that checkout is healthy.
3. Inspect the PostgreSQL Flexible Server resource health, availability, and configuration without changing it.
4. Inspect the App Service virtual network integration, subnet, private DNS path, and the application-subnet network security group.
5. Compare effective network rules, DNS resolution, routes, and recent configuration changes with the observed failure interval. Identify competing causes before proposing a diagnosis.
6. If source access was selected during setup, inspect the connected repository for relevant application behavior and configuration. Otherwise report the source-evidence gap and continue with telemetry and Azure state.

## Evidence standard

Separate confirmed facts from hypotheses. Cite resource IDs, UTC timestamps, telemetry results, and relevant source paths. State missing or contradictory evidence and confidence. No telemetry is not proof of recovery.

## Recovery boundary

Do not modify the network security group, PostgreSQL server, App Service, identities, role assignments, or agent safeguards. Present an evidence-backed mitigation proposal. The lab operator owns fault injection and reset through the local operator instructions.

After reset, require fresh successful `POST /checkout` requests and successful PostgreSQL dependencies in the new UTC interval before reporting recovery.