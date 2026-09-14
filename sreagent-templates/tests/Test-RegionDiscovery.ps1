$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "sre-region-test-$([guid]::NewGuid())"
$fakeBin = Join-Path $tempDir 'bin'
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

$azScript = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_AZ_CALLS:?}"
case "$1 $2" in
  "account show") printf '%s\n' "default-subscription" ;;
  "provider show") printf '%s\n' '["East US 2","Poland Central","North Central US (Stage)"]' ;;
    "rest --method") printf '%s\n' '[{"name":"eastus2","displayName":"East US 2"},{"name":"polandcentral","displayName":"Poland Central"}]' ;;
  *) exit 1 ;;
esac
'@
$fakeAz = Join-Path $fakeBin 'az'
[System.IO.File]::WriteAllText($fakeAz, $azScript)
& chmod +x $fakeAz

$originalPath = $env:PATH
$env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$originalPath"
$env:FAKE_AZ_CALLS = Join-Path $tempDir 'az-calls'

try {
    . (Join-Path $root 'bin/ps/Region-Utils.ps1')

    if ((Resolve-AzureSubscription) -ne 'default-subscription') { throw 'Default subscription was not resolved.' }
    if ((Resolve-AzureSubscription -Subscription 'explicit-subscription') -ne 'explicit-subscription') { throw 'Explicit subscription was not retained.' }

    $regions = @(Get-SreAgentRegions -Subscription 'target-subscription')
    if (($regions -join ',') -ne 'eastus2,polandcentral') { throw "Unexpected regions: $($regions -join ',')" }
    Assert-SreAgentRegion -Subscription 'target-subscription' -Region 'polandcentral'

    try {
        Assert-SreAgentRegion -Subscription 'target-subscription' -Region 'westus3'
        throw 'Unavailable region passed validation.'
    }
    catch {
        if ($_.Exception.Message -notlike '*supported-regions*') { throw }
    }

    $outputDir = Join-Path $tempDir 'generated-agent'
    & (Join-Path $root 'bin/ps/New-Agent.ps1') `
        -Recipe minimal `
        -Subscription target-subscription `
        -Set @{ agentName = 'region-test'; resourceGroup = 'region-test-rg'; location = 'polandcentral'; targetRGs = 'target-rg' } `
        -NonInteractive `
        -NoTelemetry `
        -Output $outputDir | Out-Null
    $generated = Get-Content (Join-Path $outputDir 'agent.json') -Raw | ConvertFrom-Json
    if ($generated.identity.subscription -ne 'target-subscription') { throw 'Generated config has the wrong subscription.' }
    if ($generated.identity.location -ne 'polandcentral') { throw 'Generated config has the wrong location.' }

    Write-Host 'PASS: PowerShell region discovery uses the selected subscription'
}
finally {
    $env:PATH = $originalPath
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}