[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$AgentName,
    [Parameter(Mandatory)][string]$StateFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Validation.ps1')
$url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/agents/$AgentName`?api-version=2025-05-01-preview"
$resolvedStateFile = (Resolve-Path $StateFile).Path
az rest --method PATCH --url $url --body "@$resolvedStateFile" --output none
if ($LASTEXITCODE -ne 0) { throw 'Failed to restore SRE Agent state.' }
$expected = (Get-Content $resolvedStateFile -Raw | ConvertFrom-Json).properties
$actual = (az rest --method GET --url $url | ConvertFrom-Json).properties
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify restored SRE Agent state.' }

function ConvertTo-SortedObject {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) { return $InputObject }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [System.Collections.IDictionary] -and $InputObject -isnot [pscustomobject]) {
        return @($InputObject | ForEach-Object { ConvertTo-SortedObject $_ })
    }
    $result = [ordered]@{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in ($InputObject.Keys | Sort-Object)) { $result[$key] = ConvertTo-SortedObject $InputObject[$key] }
    }
    else {
        foreach ($property in ($InputObject.PSObject.Properties | Sort-Object Name)) { $result[$property.Name] = ConvertTo-SortedObject $property.Value }
    }
    return $result
}

$expectedWritable = @{
    vnetConfiguration = Get-OptionalProperty $expected 'vnetConfiguration'
    sandboxConfiguration = Get-OptionalProperty $expected 'sandboxConfiguration'
}
$actualWritable = @{
    vnetConfiguration = Get-OptionalProperty $actual 'vnetConfiguration'
    sandboxConfiguration = Get-OptionalProperty $actual 'sandboxConfiguration'
}
$expectedJson = ConvertTo-SortedObject $expectedWritable | ConvertTo-Json -Depth 20 -Compress
$actualJson = ConvertTo-SortedObject $actualWritable | ConvertTo-Json -Depth 20 -Compress
if ($expectedJson -ne $actualJson) { throw 'Restored writable fields do not match the captured state.' }
Write-Host 'Agent writable network and sandbox fields restored and verified.'
