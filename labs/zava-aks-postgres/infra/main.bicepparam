using './main.bicep'

param location = 'swedencentral'
param resourceGroupName = 'rg-zava-aks-postgres'

// AZD sets AZURE_ENV_NAME automatically (e.g. 'zava-oneshot-1514'). Read it
// here so the per-env SRE Agent suffix is derivable at deployment-plan time.
// When deploying without azd (raw `az deployment sub create`), this falls back
// to '' and the agent name keeps its legacy `sre-agent-${uniqueSuffix}` shape.
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', '')
