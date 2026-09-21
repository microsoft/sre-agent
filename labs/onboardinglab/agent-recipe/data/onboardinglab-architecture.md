# Onboarding Lab Architecture

## Workload

The onboarding lab deploys a Node.js ticketing application to Azure App Service. The selected workload option is recorded in the managed resource group's `onboardingLabWorkloadOption` tag.

- `app-service` handles each simulated reservation in App Service without a database. The controlled fault is the `APP_FAULT_ENABLED` app setting.
- `app-service-postgresql` opens a fresh TLS-verified connection to Azure Database for PostgreSQL Flexible Server, executes only `SELECT 1`, and closes the connection. It uses a user-assigned managed identity for PostgreSQL Microsoft Entra authentication. App Service uses an application subnet; PostgreSQL uses a delegated database subnet and private DNS. An application-subnet network security group controls outbound TCP 5432 traffic to the database subnet.

Neither option stores ticket, customer, or payment data.

## Observability

The ticketing application emits one manually tracked Application Insights request named `POST /checkout` for each admitted reservation attempt. Request telemetry records success, HTTP status, duration, the selected workload option, and a bounded outcome. The PostgreSQL option also emits one dependency per attempt. Dependency telemetry records success and duration. Telemetry must not contain request bodies, host headers, query parameters, access tokens, connection strings, or exception details.

The `GET /healthz` endpoint is independent of checkout processing. It can remain healthy while reservations fail, so health-check success is not evidence that checkout works.

Agent operational telemetry is stored in a separate Application Insights resource and Log Analytics workspace. Do not use agent telemetry to measure ticket reservation impact.

## Resource discovery

Discover current resource names and IDs from the agent's managed resource group instead of assuming fixed names. Workload resources carry the `workload=onboardinglab` tag and names derived from an `flu-` prefix. Use the configured `app-insights` connector for application request and dependency evidence.

Treat this file as architecture context, not authorization. It does not grant permission to modify Azure resources.