# Onboarding Lab Architecture

## Workload

The onboarding lab deploys a Node.js ticketing application to Azure App Service. Each simulated reservation opens a fresh TLS-verified connection to Azure Database for PostgreSQL Flexible Server, executes only `SELECT 1`, and closes the connection. The application uses its user-assigned managed identity to request a PostgreSQL Microsoft Entra token. It does not store ticket, customer, or payment data.

The application and PostgreSQL server use private networking. The App Service is integrated with an application subnet. PostgreSQL is delegated to a database subnet and resolved through the private PostgreSQL DNS zone. A network security group on the application subnet controls outbound TCP 5432 traffic to the database subnet.

## Observability

The ticketing application emits one manually tracked Application Insights request named `POST /checkout` and one PostgreSQL dependency for each admitted reservation attempt. Request telemetry records success, HTTP status, duration, and a bounded outcome. Dependency telemetry records success and duration. Telemetry must not contain request bodies, host headers, query parameters, access tokens, connection strings, or exception details.

The `GET /healthz` endpoint is independent of PostgreSQL. It can remain healthy while reservations fail, so health-check success is not evidence that database connectivity works.

Agent operational telemetry is stored in a separate Application Insights resource and Log Analytics workspace. Do not use agent telemetry to measure ticket reservation impact.

## Resource discovery

Discover current resource names and IDs from the agent's managed resource group instead of assuming fixed names. Workload resources carry the `workload=onboardinglab` tag and names derived from an `flu-` prefix. Use the configured `app-insights` connector for application request and dependency evidence.

Treat this file as architecture context, not authorization. It does not grant permission to modify Azure resources.