# Onboarding Lab Checkout Availability Runbook

## Scope

Use this runbook when ticket reservations return HTTP 503. Establish the affected UTC interval and discover the selected option from the managed resource group's `onboardingLabWorkloadOption` tag before querying evidence.

## Read-only investigation

1. Query the configured `app-insights` connector for `POST /checkout` request count, failure count, status, and duration during the affected interval.
2. A healthy `GET /healthz` response does not prove that checkout is healthy. For `app-service`, inspect the App Service state, configuration, and recent changes, including `APP_FAULT_ENABLED` without exposing setting values unrelated to this lab.
3. For `app-service-postgresql`, correlate failed requests with PostgreSQL dependency failures and inspect PostgreSQL Flexible Server resource health, availability, and configuration without changing it.
4. For `app-service-postgresql`, inspect the App Service virtual network integration, subnet, private DNS path, and application-subnet network security group. Compare effective rules, DNS resolution, routes, and recent changes with the observed interval.
5. Identify competing causes before proposing a diagnosis. Do not claim that a resource absent from the selected option is missing evidence or a fault.
6. If source access was selected during setup, inspect the connected repository for relevant application behavior and configuration. Otherwise report the source-evidence gap and continue with telemetry and Azure state.

## Evidence standard

Separate confirmed facts from hypotheses. Cite resource IDs, UTC timestamps, telemetry results, and relevant source paths. State missing or contradictory evidence and confidence. No telemetry is not proof of recovery.

## Recovery boundary

Do not modify the App Service, network security group, PostgreSQL server, identities, role assignments, or agent safeguards. Present an evidence-backed mitigation proposal. The lab operator owns fault injection and reset through the local operator instructions.

After reset, require fresh successful `POST /checkout` requests in the new UTC interval before reporting recovery. For `app-service-postgresql`, also require fresh successful PostgreSQL dependencies.