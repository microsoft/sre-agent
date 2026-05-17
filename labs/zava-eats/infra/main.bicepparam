using './main.bicep'

param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'srelab')
param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param githubPat = readEnvironmentVariable('GITHUB_PAT', '')
