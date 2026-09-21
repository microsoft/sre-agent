# Ticketing app source

This folder is the complete Azure Developer CLI project for the onboarding lab ticketing workload. It contains the Node.js application, Bicep infrastructure, and deployment parameters required by `azd up`.

## Deploy

Install [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd), and [Node.js 22 or later](https://nodejs.org/en/download). Then run these commands from this directory:

On Windows, PowerShell 7 runs the post-deploy hook. In the full lab checkout,
that hook can opt into agent setup through `ONBOARDING_CONFIGURE_AGENT=true`.
A standalone copy deploys only the workload by default; it does not require
the sibling agent setup files. See the full lab's setup guide before selecting
agent configuration.

```bash
azd auth login
az login
azd env set LAB_WORKLOAD_OPTION app-service
azd up
```

Choose one of two equal workload options before `azd up`:

- `app-service` deploys Linux App Service and shared telemetry.
- `app-service-postgresql` adds PostgreSQL Flexible Server and private networking. Register `Microsoft.DBforPostgreSQL` before deployment and use a subscription where PostgreSQL 16 with `Standard_B1ms` is available in Sweden Central.

To select the PostgreSQL option:

```bash
az provider register --namespace Microsoft.DBforPostgreSQL --wait
azd env set LAB_WORKLOAD_OPTION app-service-postgresql
azd up
```

Retrieve the deployed application URL:

```bash
azd env get-value SERVICE_CHECKOUT_ENDPOINT_URL
```

## Validate locally

The tests do not contact Azure:

```bash
npm ci --prefix ./app --ignore-scripts --no-audit --no-fund
npm test --prefix ./app
npm run check --prefix ./app
```

## Clean up

```bash
azd down
```