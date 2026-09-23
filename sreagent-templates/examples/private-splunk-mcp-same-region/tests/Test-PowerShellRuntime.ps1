$ErrorActionPreference = 'Stop'
$exampleDir = Split-Path -Parent $PSScriptRoot
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "private-splunk-tests-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    $parametersPath = Join-Path $tempDir 'parameters.json'
    @{
        parameters = @{
            adminSshPublicKey = @{
                value = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBogusButValidBase64ForOfflineValidation'
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $parametersPath

    function global:az {
        $global:LASTEXITCODE = 0
        $command = $args -join ' '

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
                return '{"location":"East US 2","properties":{"vnetConfiguration":{"existingVnetSetting":"keep-vnet"},"sandboxConfiguration":{"packages":[{"name":"requests","packageManager":"pip"}],"egress":{"allowedHosts":["existing.example"],"allowedRegistries":["pypi"],"vnetConfiguration":{"existingDnsSetting":"keep-dns"}}}}}'
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
            return
        }
    }

    $global:LASTEXITCODE = 0
    & (Join-Path $exampleDir 'scripts/Deploy.ps1') -Backend Bicep -ResourceGroup 'offline-test-rg' -ParametersFile $parametersPath
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
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
