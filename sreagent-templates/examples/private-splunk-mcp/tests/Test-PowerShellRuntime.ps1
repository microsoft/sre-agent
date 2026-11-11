$ErrorActionPreference = 'Stop'
$exampleDir = Split-Path -Parent $PSScriptRoot
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "private-splunk-tests-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $parametersPath = Join-Path $tempDir 'parameters.json'
    @{
        parameters = @{
            topology = @{ value = 'cross-region' }
            agentLocation = @{ value = 'eastus2' }
            splunkLocation = @{ value = 'centralus' }
            agentVnetAddressPrefix = @{ value = '10.20.0.0/16' }
            splunkVnetAddressPrefix = @{ value = '10.40.0.0/16' }
            agentSubnetPrefix = @{ value = '10.20.0.0/27' }
            splunkSubnetPrefix = @{ value = '10.40.1.0/24' }
            splunkPrivateIp = @{ value = '10.40.1.4' }
            adminSshPublicKey = @{
                value = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButValidBase64ForOfflineValidation'
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $parametersPath
    $sameRegionParametersPath = Join-Path $tempDir 'same-region.parameters.json'
    @{
        parameters = @{
            topology = @{ value = 'same-region' }
            agentLocation = @{ value = 'eastus2' }
            agentVnetAddressPrefix = @{ value = '10.100.0.0/16' }
            agentSubnetPrefix = @{ value = '10.100.0.0/27' }
            splunkSubnetPrefix = @{ value = '10.100.1.0/24' }
            splunkPrivateIp = @{ value = '10.100.1.4' }
            adminSshPublicKey = @{ value = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButValidBase64ForOfflineValidation' }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $sameRegionParametersPath

    function global:az {
        $global:LASTEXITCODE = 0
        $command = $args -join ' '

        if ($command -match '^group create ') {
            $global:groupCreateCount++
            return
        }

        if ($command -match '^vm show ') {
            return 'eastus2'
        }

        if ($command -match '^vm run-command create ') {
            if ($command -match '--script true') {
                $global:scrubCallObserved = $true
                if ($global:forceScrubFailure) {
                    $global:LASTEXITCODE = 1
                    return 'offline scrub failure'
                }
            }
            else {
                $global:runCommandExists = $true
                $global:mintCreateCommand = $command
                if ($global:forceInitialCreateFailure) {
                    $global:LASTEXITCODE = 1
                    return 'offline client timeout'
                }
            }
            return
        }

        if ($command -match '^vm run-command delete ') {
            $global:deleteCallObserved = $true
            if ($global:forceDeleteFailure) {
                $global:LASTEXITCODE = 1
                return 'offline delete failure'
            }
            $global:runCommandExists = $false
            return
        }

        if ($command -match '^vm run-command show ' -and $command -match '--output none') {
            if ($global:runCommandExists) {
                return
            }
            $global:LASTEXITCODE = 1
            return 'ResourceNotFound: run command does not exist'
        }

        if ($command -match '^vm run-command show ') {
            if ($global:mintGuestFailure) {
                return '{"exitCode":9,"output":"offline guest failure","error":"offline guest error"}'
            }
            return '{"exitCode":0,"output":"offline-encrypted-token","error":""}'
        }

        if ($args[0] -eq 'rest' -and $args -contains 'GET') {
            if (($args -join ' ') -match '/providers/Microsoft\.App/agents/') {
                return $global:agentState | ConvertTo-Json -Depth 20 -Compress
            }

            return 'eastus2'
        }

        if ($args[0] -eq 'rest' -and $args -contains 'PATCH') {
            $bodyIndex = [Array]::IndexOf($args, '--body')
            if ($bodyIndex -lt 0 -or $args[$bodyIndex + 1] -notlike '@*') {
                $global:LASTEXITCODE = 1
                return 'PATCH body was not passed by file.'
            }

            $bodyPath = $args[$bodyIndex + 1].Substring(1)
            $global:patchBody = Get-Content $bodyPath -Raw | ConvertFrom-Json
            foreach ($propertyName in @('vnetConfiguration', 'sandboxConfiguration')) {
                $patchProperty = $global:patchBody.properties.PSObject.Properties[$propertyName]
                if ($null -eq $patchProperty -or $null -eq $patchProperty.Value) {
                    $global:agentState.properties.PSObject.Properties.Remove($propertyName)
                }
                else {
                    $global:agentState.properties | Add-Member -NotePropertyName $propertyName -NotePropertyValue $patchProperty.Value -Force
                }
            }
            return
        }
    }

    $global:LASTEXITCODE = 0
    $global:groupCreateCount = 0
    $global:agentState = '{"location":"East US 2","properties":{"vnetConfiguration":{"existingVnetSetting":"keep-vnet"},"sandboxConfiguration":{"packages":[{"name":"requests","packageManager":"pip"}],"egress":{"allowedHosts":["existing.example"],"allowedRegistries":["pypi"],"vnetConfiguration":{"existingDnsSetting":"keep-dns"}}}}}' | ConvertFrom-Json
    & (Join-Path $exampleDir 'scripts/Deploy.ps1') -Backend Bicep -ResourceGroup 'offline-test-rg' -ParametersFile $parametersPath
    & (Join-Path $exampleDir 'scripts/Deploy.ps1') -Backend Bicep -ResourceGroup 'offline-test-rg' -ParametersFile $sameRegionParametersPath
    if ($global:groupCreateCount -ne 2) { throw 'Deploy.ps1 did not exercise both topology modes.' }
    $invalidParametersPath = Join-Path $tempDir 'invalid.parameters.json'
    @{ parameters = @{ topology = @{ value = 'unsupported' }; adminSshPublicKey = @{ value = 'invalid-key' } } } |
        ConvertTo-Json -Depth 5 | Set-Content $invalidParametersPath
    try {
        & (Join-Path $exampleDir 'scripts/Deploy.ps1') -Backend Bicep -ResourceGroup 'must-not-be-created' -ParametersFile $invalidParametersPath
        throw 'Deploy.ps1 accepted invalid inputs.'
    }
    catch {
        if ($_.Exception.Message -eq 'Deploy.ps1 accepted invalid inputs.') { throw }
    }
    if ($global:groupCreateCount -ne 2) { throw 'Deploy.ps1 created a resource group before rejecting invalid inputs.' }
    . (Join-Path $exampleDir 'scripts/Validation.ps1')
    Test-DeploymentInputs 'same-region' 'eastus2' 'eastus2' '10.100.0.0/16' '10.100.0.0/16' '10.100.0.0/27' '10.100.1.0/24' '10.100.1.4' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButValidBase64ForOfflineValidation'
    Test-DeploymentInputs 'cross-region' 'eastus2' 'centralus' '10.20.0.0/16' '10.40.0.0/16' '10.20.0.0/27' '10.40.1.0/24' '10.40.1.4' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButValidBase64ForOfflineValidation'
    foreach ($invalidCase in @(
        @('unsupported', 'eastus2', 'eastus2', '10.100.0.0/16', '10.100.0.0/16', '10.100.0.0/27', '10.100.1.0/24', '10.100.1.4'),
        @('cross-region', 'eastus2', 'eastus2', '10.20.0.0/16', '10.40.0.0/16', '10.20.0.0/27', '10.40.1.0/24', '10.40.1.4'),
        @('cross-region', 'eastus2', 'centralus', '10.20.0.0/16', '10.20.0.0/16', '10.20.0.0/27', '10.20.1.0/24', '10.20.1.4'),
        @('same-region', 'eastus2', 'eastus2', '10.100.0.0/16', '10.100.0.0/16', '10.100.1.0/27', '10.100.1.0/24', '10.100.1.4'),
        @('same-region', 'eastus2', 'eastus2', '10.100.0.0/16', '10.100.0.0/16', '10.101.0.0/27', '10.100.1.0/24', '10.100.1.4'),
        @('same-region', 'eastus2', 'eastus2', '10.100.0.0/16', '10.100.0.0/16', '10.100.0.0/27', '10.100.1.0/24', '10.100.2.4'),
        @('same-region', 'eastus2', 'eastus2', '10.100.0.0/16', '10.100.0.0/16', '10.100.0.0/27', '10.100.1.0/24', '10.100.1.3')
    )) {
        $failed = $false
        try {
            Test-DeploymentInputs @invalidCase 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButValidBase64ForOfflineValidation'
        }
        catch {
            $failed = $true
        }
        if (-not $failed) { throw "Expected validation failure for $($invalidCase -join ', ')." }
    }
    & (Join-Path $exampleDir 'scripts/Patch-Agent.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -SubnetId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/offline-test-rg/providers/Microsoft.Network/virtualNetworks/offline-test-vnet/subnets/agent-subnet'
    if ($global:patchBody.properties.vnetConfiguration.existingVnetSetting -ne 'keep-vnet' -or
        $global:patchBody.properties.sandboxConfiguration.packages[0].name -ne 'requests' -or
        $global:patchBody.properties.sandboxConfiguration.egress.allowedHosts[0] -ne 'existing.example' -or
        $global:patchBody.properties.sandboxConfiguration.egress.allowedRegistries[0] -ne 'pypi' -or
        $global:patchBody.properties.sandboxConfiguration.egress.vnetConfiguration.existingDnsSetting -ne 'keep-dns' -or
        $global:patchBody.properties.sandboxConfiguration.egress.mode -ne 'AzureVNet' -or
        $global:patchBody.properties.sandboxConfiguration.egress.allowHttpMcpServerNetworkAccess -ne $false -or
        $global:patchBody.properties.sandboxConfiguration.egress.vnetConfiguration.usePrivateDnsResolution -ne $true) {
        throw 'Patch-Agent.ps1 did not preserve existing sandbox and VNet settings while applying private MCP routing.'
    }

    $statePath = Join-Path $tempDir 'agent-state.json'
    & (Join-Path $exampleDir 'scripts/Capture-AgentState.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -OutputFile $statePath
    $capturedState = Get-Content $statePath -Raw | ConvertFrom-Json
    $capturedPropertyNames = @($capturedState.PSObject.Properties | ForEach-Object Name)
    if ($capturedPropertyNames.Count -ne 1 -or
        $capturedPropertyNames[0] -ne 'properties' -or
        $capturedState.properties.vnetConfiguration.existingVnetSetting -ne 'keep-vnet' -or
        $capturedState.properties.sandboxConfiguration.packages[0].name -ne 'requests') {
        throw 'Capture-AgentState.ps1 did not capture only the writable fields.'
    }
    & (Join-Path $exampleDir 'scripts/Restore-AgentState.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -StateFile $statePath

    $global:agentState = '{"location":"East US 2","properties":{}}' | ConvertFrom-Json
    $emptyStatePath = Join-Path $tempDir 'agent-state-empty.json'
    & (Join-Path $exampleDir 'scripts/Capture-AgentState.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -OutputFile $emptyStatePath
    $emptyState = Get-Content $emptyStatePath -Raw | ConvertFrom-Json
    if ($null -ne $emptyState.properties.vnetConfiguration -or $null -ne $emptyState.properties.sandboxConfiguration) {
        throw 'Capture-AgentState.ps1 did not preserve absent writable fields as null.'
    }
    & (Join-Path $exampleDir 'scripts/Patch-Agent.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -SubnetId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/offline-test-rg/providers/Microsoft.Network/virtualNetworks/offline-test-vnet/subnets/agent-subnet'
    & (Join-Path $exampleDir 'scripts/Restore-AgentState.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -StateFile $emptyStatePath
    if ($null -ne $global:agentState.properties.PSObject.Properties['vnetConfiguration'] -or
        $null -ne $global:agentState.properties.PSObject.Properties['sandboxConfiguration']) {
        throw 'Restore-AgentState.ps1 did not clear writable fields that were originally absent.'
    }

    $global:scrubCallObserved = $false
    $global:deleteCallObserved = $false
    function global:Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        return ConvertTo-SecureString 'offline-password' -AsPlainText -Force
    }
    function global:Start-Sleep {}

    $global:mintGuestFailure = $false
    $global:forceScrubFailure = $false
    $global:forceDeleteFailure = $false
    $global:forceInitialCreateFailure = $false
    $global:runCommandExists = $false
    & (Join-Path $exampleDir 'scripts/Mint-McpToken.ps1') -ResourceGroup 'offline-test-rg' -VmName 'offline-test-vm' -Scheme http -Days 1 -Username 'readonly-user'
    if ($LASTEXITCODE -ne 0) {
        throw "Mint-McpToken.ps1 left a failing native exit code after verified cleanup: $LASTEXITCODE"
    }
    if (-not $global:scrubCallObserved) {
        throw 'Mint-McpToken.ps1 did not scrub Managed Run Command output before cleanup.'
    }
    if (-not $global:deleteCallObserved) {
        throw 'Mint-McpToken.ps1 did not delete the Managed Run Command resource.'
    }
    if ($global:mintCreateCommand -notmatch 'username=readonly-user') {
        throw 'Mint-McpToken.ps1 did not pass the requested token username to the VM.'
    }

    $global:forceInitialCreateFailure = $true
    $global:runCommandExists = $false
    $global:scrubCallObserved = $false
    $global:deleteCallObserved = $false
    $clientFailure = $null
    try {
        & (Join-Path $exampleDir 'scripts/Mint-McpToken.ps1') -ResourceGroup 'offline-test-rg' -VmName 'offline-test-vm' -Scheme http -Days 1
    }
    catch {
        $clientFailure = $_.Exception.Message
    }
    if ($clientFailure -notmatch 'MCP token creation failed') {
        throw "Mint-McpToken.ps1 did not preserve the client-side create failure: $clientFailure"
    }
    if (-not $global:scrubCallObserved -or -not $global:deleteCallObserved) {
        throw 'Mint-McpToken.ps1 did not clean up after a client-side create failure with a server-side resource.'
    }

    $global:forceInitialCreateFailure = $false
    $global:mintGuestFailure = $true
    $global:forceScrubFailure = $true
    $global:forceDeleteFailure = $true
    $global:scrubCallObserved = $false
    $global:deleteCallObserved = $false
    $mintFailure = $null
    try {
        & (Join-Path $exampleDir 'scripts/Mint-McpToken.ps1') -ResourceGroup 'offline-test-rg' -VmName 'offline-test-vm' -Scheme http -Days 1
    }
    catch {
        $mintFailure = $_.Exception.Message
    }
    if ($mintFailure -notmatch 'MCP token creation failed on the VM: offline guest error') {
        throw "Mint-McpToken.ps1 did not preserve the original guest failure: $mintFailure"
    }
    if (-not $global:scrubCallObserved -or -not $global:deleteCallObserved) {
        throw 'Mint-McpToken.ps1 did not attempt both cleanup operations after a guest failure.'
    }

    if ($IsWindows) {
        Remove-Item Function:\az
        $capturePath = Join-Path $tempDir 'native-patch.json'
        $shimPath = Join-Path $tempDir 'az-shim.ps1'
        @'
$ErrorActionPreference = 'Stop'
$command = $args -join ' '
if ($args[0] -eq 'rest' -and $args -contains 'GET') {
    if ($command -match '/providers/Microsoft\.App/agents/') {
        '{"location":"East US 2","properties":{"sandboxConfiguration":{"packages":[{"name":"native-package","packageManager":"pip"}],"egress":{"allowedHosts":["native.example"]}}}}'
    }
    else {
        'eastus2'
    }
    exit 0
}
if ($args[0] -eq 'rest' -and $args -contains 'PATCH') {
    $bodyIndex = [Array]::IndexOf($args, '--body')
    $bodyArgument = $args[$bodyIndex + 1]
    if ($bodyIndex -lt 0 -or -not $bodyArgument.StartsWith('@')) {
        exit 12
    }
    $body = Get-Content $bodyArgument.Substring(1) -Raw | ConvertFrom-Json
    $body | ConvertTo-Json -Depth 20 | Set-Content -Path $env:AZ_SHIM_CAPTURE -Encoding utf8
    exit 0
}
exit 13
'@ | Set-Content -Path $shimPath -Encoding utf8
        "@echo off`r`npwsh -NoProfile -File `"%~dp0az-shim.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n" |
            Set-Content -Path (Join-Path $tempDir 'az.cmd') -Encoding ascii

        $previousPath = $env:PATH
        $env:PATH = "$tempDir;$previousPath"
        $env:AZ_SHIM_CAPTURE = $capturePath
        try {
            $patchScript = Join-Path $exampleDir 'scripts/Patch-Agent.ps1'
            & pwsh -NoProfile -Command "& { `$PSNativeCommandArgumentPassing = 'Legacy'; & '$patchScript' -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -SubnetId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/offline-test-rg/providers/Microsoft.Network/virtualNetworks/offline-test-vnet/subnets/agent-subnet' }"
            if ($LASTEXITCODE -ne 0) {
                throw "Patch-Agent.ps1 failed through native az.cmd with exit code $LASTEXITCODE."
            }
            $nativePatchBody = Get-Content $capturePath -Raw | ConvertFrom-Json
            if ($nativePatchBody.properties.sandboxConfiguration.packages[0].name -ne 'native-package' -or
                $nativePatchBody.properties.sandboxConfiguration.egress.allowedHosts[0] -ne 'native.example' -or
                $nativePatchBody.properties.sandboxConfiguration.egress.mode -ne 'AzureVNet') {
                throw 'Native az.cmd PATCH body was corrupted or lost existing settings.'
            }
        }
        finally {
            $env:PATH = $previousPath
            Remove-Item Env:\AZ_SHIM_CAPTURE -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Variable scrubCallObserved -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable deleteCallObserved -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable mintGuestFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable forceInitialCreateFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable forceScrubFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable forceDeleteFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable runCommandExists -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable mintCreateCommand -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable patchBody -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable groupCreateCount -Scope Global -ErrorAction SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
