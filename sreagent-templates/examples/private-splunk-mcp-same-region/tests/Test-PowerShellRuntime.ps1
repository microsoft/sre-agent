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
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
