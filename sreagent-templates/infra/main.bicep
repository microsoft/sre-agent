// no-op — azd infra provisioning handled by preprovision hook (deploy.sh)
targetScope = 'subscription'

param location string = ''

output AZURE_LOCATION string = location
