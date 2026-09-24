[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$AgentName,

    [Parameter(Mandatory)]
    [string]$SubnetId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalProperty {
    param($InputObject, [string]$Name)

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

$agentUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName`?api-version=2025-05-01-preview"
$vnetId = $SubnetId -replace '/subnets/[^/]+$', ''
$vnetUrl = "https://management.azure.com$vnetId`?api-version=2025-03-01"

$agent = az rest --method GET --url $agentUrl | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the SRE Agent resource.'
}

$vnetLocation = az rest --method GET --url $vnetUrl --query location --output tsv
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the agent VNet resource.'
}

if ($agent.location -ne $vnetLocation) {
    throw "Agent region '$($agent.location)' does not match agent VNet region '$vnetLocation'."
}

$currentSubnet = Get-OptionalProperty (Get-OptionalProperty (Get-OptionalProperty $agent 'properties') 'vnetConfiguration') 'subnetResourceId'
if ($currentSubnet -and $currentSubnet -ne $SubnetId) {
    throw "The agent is already attached to a different subnet: $currentSubnet. This script will not reassign an existing VNet integration."
}

$body = @{
    properties = @{
        vnetConfiguration = @{
            subnetResourceId = $SubnetId
        }
        sandboxConfiguration = @{
            egress = @{
                mode = 'AzureVNet'
                allowHttpMcpServerNetworkAccess = $false
                vnetConfiguration = @{
                    usePrivateDnsResolution = $true
                }
            }
        }
    }
} | ConvertTo-Json -Depth 8 -Compress

az rest --method PATCH --url $agentUrl --body $body --output none
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure SRE Agent VNet integration.'
}

Write-Host 'Agent VNet integration configured.'
Write-Host 'Remote MCP infra-network bypass is disabled; private MCP traffic must use the customer VNet.'
