# Onboarding Lab Database Connectivity Runbook

## Scope

Use this runbook when ticket reservations return HTTP 503 or the `POST /checkout` dependency to PostgreSQL fails. Establish the affected UTC interval before querying evidence.

## Read-only investigation

1. Query the configured `app-insights` connector for `POST /checkout` request count, failure count, status, and duration during the affected interval.
2. Correlate failed requests with PostgreSQL dependency failures. A healthy `GET /healthz` response does not prove that ticket reservations are healthy.
3. Inspect the PostgreSQL Flexible Server resource health, availability, and configuration without changing it.
4. Inspect the App Service virtual network integration, subnet, private DNS path, and the application-subnet network security group.
5. Check the outbound rule named `PostgreSqlFaultInjection`. A Deny action for TCP 5432 from the application subnet to the database subnet explains simultaneous reservation request and PostgreSQL dependency failures when PostgreSQL itself remains healthy.
6. Review the connected `ticketingapp-source` repository to confirm that each reservation creates a fresh connection, uses Microsoft Entra authentication, enforces TLS validation, executes only `SELECT 1`, and applies one five-second deadline.

## Evidence standard

Separate confirmed facts from hypotheses. Cite resource IDs, UTC timestamps, telemetry results, and relevant source paths. State missing or contradictory evidence and confidence. No telemetry is not proof of recovery.

## Recovery boundary

Do not modify the network security group, PostgreSQL server, App Service, identities, role assignments, or agent safeguards. Recommend the narrow reversible reset and let the lab operator run the documented fault-reset command.

After reset, require fresh successful `POST /checkout` requests and successful PostgreSQL dependencies in the new UTC interval before reporting recovery.