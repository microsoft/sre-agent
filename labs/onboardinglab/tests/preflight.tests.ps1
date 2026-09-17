#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$global:PreflightCase = 'ready'
$global:PreflightCalls = [System.Collections.Generic.List[string]]::new()
function global:az {
    $command = $args -join ' '
    $global:PreflightCalls.Add($command)
    $global:LASTEXITCODE = 0
    if ($global:PreflightCase -eq 'cli-failure') {
        $global:LASTEXITCODE = 1
        return
    }
    if ($command -like 'account show*') {
        return '{"id":"00000000-0000-0000-0000-000000000001","state":"Enabled"}'
    }
    if ($command -like 'provider show*') {
        if ($global:PreflightCase -eq 'unregistered') { return '{"registrationState":"NotRegistered","resourceTypes":[{"resourceType":"agents","locations":["Sweden Central"]}]}' }
        return '{"registrationState":"Registered","resourceTypes":[{"resourceType":"agents","locations":["Sweden Central"]}]}'
    }
    if ($command -like 'postgres flexible-server list-skus*') {
        if ($global:PreflightCase -eq 'restricted') {
            return '[{"reason":"Subscription offer restricted","supportedServerVersions":[],"supportedServerEditions":[]}]'
        }
        if ($global:PreflightCase -eq 'no-sku') {
            return '[{"supportedServerVersions":[{"name":"16"}],"supportedServerEditions":[]}]'
        }
        return '[{"supportedServerVersions":[{"name":"16"}],"supportedServerEditions":[{"supportedServerSkus":[{"name":"Standard_B1ms"}]}]}]'
    }
    throw "Unexpected Azure command: $command"
}
foreach ($name in @('azd', 'node', 'npm', 'jq')) {
    Set-Item "Function:global:$name" { throw 'Preflight must only check command presence.' }
}
try {
    $scriptPath = Join-Path $PSScriptRoot '..\scripts\preflight.ps1'
    $result = & $scriptPath -Subscription '00000000-0000-0000-0000-000000000001' -Location swedencentral
    if ($result.ProviderRegistration -ne 'Ready') { throw 'Expected a ready preflight.' }
    foreach ($case in @('restricted', 'no-sku', 'unregistered', 'cli-failure')) {
        $global:PreflightCase = $case
        $failed = $false
        try { $null = & $scriptPath -Subscription '00000000-0000-0000-0000-000000000001' -Location swedencentral }
        catch { $failed = $true }
        if (-not $failed) { throw "Expected $case to fail." }
    }
    if (@($global:PreflightCalls | Where-Object { $_ -match '\b(create|delete|register|update)\b' }).Count) {
        throw 'Preflight attempted a state-changing command.'
    }
    Write-Host 'PASS: preflight checks available version/SKU and registrations, fails explicitly, and performs no writes.'
}
finally {
    foreach ($name in @('az', 'azd', 'node', 'npm', 'jq')) {
        Remove-Item "Function:global:$name"
    }
}
