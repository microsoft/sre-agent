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
            return
        }

        if ($command -match '^vm run-command delete ') {
            $global:deleteCallObserved = $true
            if ($global:forceDeleteFailure) {
                $global:LASTEXITCODE = 1
                return 'offline delete failure'
            }
            return
        }

        if ($command -match '^vm run-command show ' -and $command -match '--output none') {
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
                return '{"location":"eastus2","properties":{}}'
            }

            return 'eastus2'
        }
    }

    $global:LASTEXITCODE = 0
    & (Join-Path $exampleDir 'scripts/Deploy.ps1') -Backend Bicep -ResourceGroup 'offline-test-rg' -ParametersFile $parametersPath
    & (Join-Path $exampleDir 'scripts/Patch-Agent.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'offline-test-rg' -AgentName 'offline-test-agent' -SubnetId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/offline-test-rg/providers/Microsoft.Network/virtualNetworks/offline-test-vnet/subnets/agent-subnet'

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
    & (Join-Path $exampleDir 'scripts/Mint-McpToken.ps1') -ResourceGroup 'offline-test-rg' -VmName 'offline-test-vm' -Scheme http -Days 1
    if ($LASTEXITCODE -ne 0) {
        throw "Mint-McpToken.ps1 left a failing native exit code after verified cleanup: $LASTEXITCODE"
    }
    if (-not $global:scrubCallObserved) {
        throw 'Mint-McpToken.ps1 did not scrub Managed Run Command output before cleanup.'
    }
    if (-not $global:deleteCallObserved) {
        throw 'Mint-McpToken.ps1 did not delete the Managed Run Command resource.'
    }

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
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Variable scrubCallObserved -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable deleteCallObserved -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable mintGuestFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable forceScrubFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable forceDeleteFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
