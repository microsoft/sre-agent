# Ticketing app source

This folder is the complete Azure Developer CLI project for the onboarding lab ticketing workload. It contains the Node.js application, Bicep infrastructure, and deployment parameters required by `azd up`.

## Deploy

Install [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd), and [Node.js 22 or later](https://nodejs.org/en/download). Then run these commands from this directory:

```bash
azd auth login
az login
az provider register --namespace Microsoft.DBforPostgreSQL --wait
azd up
```

Choose an Azure SRE Agent supported region that also supports Linux App Service and Azure Database for PostgreSQL Flexible Server for your subscription.

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