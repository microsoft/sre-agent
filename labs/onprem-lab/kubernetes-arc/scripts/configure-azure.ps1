[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [string]$ClusterName = $env:COMPUTERNAME.ToLowerInvariant(),

    [string]$WorkspaceName
)

$ErrorActionPreference = 'Stop'

if (-not $WorkspaceName) {
    $WorkspaceName = "$ClusterName-amw"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required.'
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl is required.'
}

az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    az login
    if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
}

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw 'Unable to select the subscription.' }

$providers = @(
    'Microsoft.Kubernetes',
    'Microsoft.KubernetesConfiguration',
    'Microsoft.ExtendedLocation',
    'Microsoft.Insights',
    'Microsoft.Monitor',
    'Microsoft.AlertsManagement',
    'Microsoft.OperationalInsights',
    'Microsoft.Dashboard'
)

foreach ($provider in $providers) {
    Write-Host "Registering $provider..."
    az provider register --namespace $provider --wait
    if ($LASTEXITCODE -ne 0) { throw "Failed to register $provider." }
}

az extension add --name connectedk8s --upgrade --yes
if ($LASTEXITCODE -ne 0) { throw 'Unable to install connectedk8s extension.' }
az extension add --name k8s-extension --upgrade --yes
if ($LASTEXITCODE -ne 0) { throw 'Unable to install k8s-extension extension.' }

az group create --name $ResourceGroupName --location $Region --output none
if ($LASTEXITCODE -ne 0) { throw 'Unable to create or update the resource group.' }

az connectedk8s show --name $ClusterName --resource-group $ResourceGroupName 1>$null 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Arc-enabled cluster $ClusterName already exists."
} else {
    az connectedk8s connect --name $ClusterName --resource-group $ResourceGroupName --location $Region --yes
    if ($LASTEXITCODE -ne 0) { throw 'Unable to connect the cluster to Azure Arc.' }
}

az monitor account show --name $WorkspaceName --resource-group $ResourceGroupName 1>$null 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Azure Monitor workspace $WorkspaceName already exists."
} else {
    az monitor account create --name $WorkspaceName --resource-group $ResourceGroupName --location $Region --output none
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create the Azure Monitor workspace.' }
}

$workspaceId = az monitor account show --name $WorkspaceName --resource-group $ResourceGroupName --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $workspaceId) { throw 'Unable to retrieve the Azure Monitor workspace ID.' }

az k8s-extension show --name azuremonitor-metrics --cluster-type connectedClusters --cluster-name $ClusterName --resource-group $ResourceGroupName 1>$null 2>$null
if ($LASTEXITCODE -eq 0) {
    az k8s-extension update --name azuremonitor-metrics --cluster-type connectedClusters --cluster-name $ClusterName --resource-group $ResourceGroupName --configuration-settings "azure-monitor-workspace-resource-id=$workspaceId" --output none
} else {
    az k8s-extension create --name azuremonitor-metrics --extension-type Microsoft.AzureMonitor.Containers.Metrics --cluster-type connectedClusters --cluster-name $ClusterName --resource-group $ResourceGroupName --configuration-settings "azure-monitor-workspace-resource-id=$workspaceId" --release-train stable --auto-upgrade-minor-version true --output none
}
if ($LASTEXITCODE -ne 0) { throw 'Unable to configure the Azure Monitor metrics extension.' }

Write-Host ''
Write-Host 'Azure Arc and Managed Prometheus configuration completed.'
Write-Host "Cluster:   $ClusterName"
Write-Host "Workspace: $WorkspaceName"
az connectedk8s show --name $ClusterName --resource-group $ResourceGroupName --query connectivityStatus -o tsv
az k8s-extension show --name azuremonitor-metrics --cluster-type connectedClusters --cluster-name $ClusterName --resource-group $ResourceGroupName --query provisioningState -o tsv
