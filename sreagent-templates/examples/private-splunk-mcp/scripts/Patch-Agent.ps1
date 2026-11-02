[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$AgentName,
    [Parameter(Mandatory)][string]$SubnetId,
    [switch]$AllowSubnetReassignment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.ps1')

function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return @{} }
    return $InputObject | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
}

$agentUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName`?api-version=2025-05-01-preview"
$vnetId = $SubnetId -replace '/subnets/[^/]+$', ''
$agent = az rest --method GET --url $agentUrl | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the SRE Agent resource.' }
$vnetLocation = az rest --method GET --url "https://management.azure.com$vnetId`?api-version=2025-03-01" --query location --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the agent VNet resource.' }
if ((Normalize-AzureLocation $agent.location) -ne (Normalize-AzureLocation $vnetLocation)) {
    throw "Agent region '$($agent.location)' does not match agent VNet region '$vnetLocation'."
}

$properties = Get-OptionalProperty $agent 'properties'
$currentSubnet = Get-OptionalProperty (Get-OptionalProperty $properties 'vnetConfiguration') 'subnetResourceId'
if ($currentSubnet -and $currentSubnet -ne $SubnetId -and -not $AllowSubnetReassignment) {
    throw "The agent is already attached to a different subnet: $currentSubnet. Pass -AllowSubnetReassignment only after capturing the original agent state."
}

$vnetConfiguration = ConvertTo-Hashtable (Get-OptionalProperty $properties 'vnetConfiguration')
$vnetConfiguration['subnetResourceId'] = $SubnetId
$sandboxConfiguration = ConvertTo-Hashtable (Get-OptionalProperty $properties 'sandboxConfiguration')
$egress = ConvertTo-Hashtable $sandboxConfiguration['egress']
$egressVnetConfiguration = ConvertTo-Hashtable $egress['vnetConfiguration']
$egressVnetConfiguration['usePrivateDnsResolution'] = $true
$egress['mode'] = 'AzureVNet'
$egress['allowHttpMcpServerNetworkAccess'] = $false
$egress['vnetConfiguration'] = $egressVnetConfiguration
$sandboxConfiguration['egress'] = $egress
$body = @{ properties = @{ vnetConfiguration = $vnetConfiguration; sandboxConfiguration = $sandboxConfiguration } } | ConvertTo-Json -Depth 20 -Compress

$bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "patch-sre-agent-$([Guid]::NewGuid()).json"
try {
    [System.IO.File]::WriteAllText($bodyPath, $body, [System.Text.UTF8Encoding]::new($false))
    az rest --method PATCH --url $agentUrl --body "@$bodyPath" --output none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to configure SRE Agent VNet integration.' }
}
finally {
    Remove-Item $bodyPath -Force -ErrorAction SilentlyContinue
}
Write-Host 'Agent VNet integration configured.'
