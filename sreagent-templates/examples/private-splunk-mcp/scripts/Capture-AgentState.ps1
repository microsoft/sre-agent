[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$AgentName,
    [Parameter(Mandatory)][string]$OutputFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.ps1')
$url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName`?api-version=2025-05-01-preview"
$agent = az rest --method GET --url $url | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the SRE Agent resource.' }
$properties = Get-OptionalProperty $agent 'properties'
$body = @{
    properties = @{
        vnetConfiguration = Get-OptionalProperty $properties 'vnetConfiguration'
        sandboxConfiguration = Get-OptionalProperty $properties 'sandboxConfiguration'
    }
} | ConvertTo-Json -Depth 20
$resolvedOutputFile = [System.IO.Path]::GetFullPath($OutputFile)
[System.IO.File]::WriteAllText($resolvedOutputFile, $body, [System.Text.UTF8Encoding]::new($false))
Write-Host "Captured writable agent network and sandbox fields in $OutputFile."
