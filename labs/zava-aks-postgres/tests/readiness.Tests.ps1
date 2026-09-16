#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$lab = Split-Path $PSScriptRoot -Parent
. (Join-Path $lab 'scripts\_sre-config.ps1')

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected failure matching: $Pattern"
}

$script:responses = [Collections.Generic.Queue[object]]::new()
$script:calls = 0
$client = [pscustomobject]@{}
$client | Add-Member ScriptMethod GetAsync {
    param($Uri, $CancellationToken)
    $script:calls++
    Assert ($Uri -eq 'https://agent.example/api/v2/extendedAgent/skills') 'Readiness uses the authenticated configuration API'
    $spec = if ($script:responses.Count) { $script:responses.Dequeue() } else { @{ status = 503; body = '' } }
    if ($spec.ContainsKey('error')) {
        return [Threading.Tasks.Task]::FromException[Net.Http.HttpResponseMessage]($spec.error)
    }
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$spec.status)
    $response.Content = [Net.Http.StringContent]::new($spec.body)
    return [Threading.Tasks.Task]::FromResult($response)
}
foreach ($status in @(404, 502, 429)) { $script:responses.Enqueue(@{status=$status; body=''}) }
$script:responses.Enqueue(@{status=200; body='{"value":[]}'})
Wait-ZavaDataPlane -Client $client -Endpoint 'https://agent.example' -TimeoutSeconds 5 -PollSeconds 0
Assert ($script:calls -eq 4) 'Transient startup failures recover before configuration writes'
$script:responses.Enqueue(@{error=[Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::ConnectionError, 'connection unavailable', $null, $null)})
$script:responses.Enqueue(@{error=[Threading.Tasks.TaskCanceledException]::new('timed out')})
$script:responses.Enqueue(@{status=200; body='[]'})
Wait-ZavaDataPlane $client 'https://agent.example' -TimeoutSeconds 5 -PollSeconds 0
$script:responses.Enqueue(@{error=[Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::SecureConnectionError, 'certificate validation failed', $null, $null)})
$before = $script:calls
Assert-Throws { Wait-ZavaDataPlane $client 'https://agent.example' -TimeoutSeconds 5 -PollSeconds 0 } 'certificate validation failed'
Assert ($script:calls -eq $before + 1) 'Certificate failures are not treated as startup'
foreach ($status in @(400, 401, 403)) {
    $script:responses.Enqueue(@{status=$status; body='denied'})
    $before = $script:calls
    Assert-Throws { Wait-ZavaDataPlane $client 'https://agent.example' -TimeoutSeconds 5 -PollSeconds 0 } "HTTP $status"
    Assert ($script:calls -eq $before + 1) 'Terminal errors are not retried'
}
$script:responses.Enqueue(@{status=200; body='{}'})
Assert-Throws { Wait-ZavaDataPlane $client 'https://agent.example' -TimeoutSeconds 5 -PollSeconds 0 } 'resource collection'
Assert-Throws { Wait-ZavaDataPlane $client 'https://agent.example' -TimeoutSeconds 1 -PollSeconds 1 } 'not ready within 1 seconds'

$setupAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $lab 'scripts\setup-sre-agent.ps1'), [ref]$null, [ref]$null)
$armRequest = $setupAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ZavaArmRequest'
}, $false)
# Load only the transport function, not the setup script's authentication or writes.
Invoke-Expression $armRequest.Extent.Text
$script:armDelay = $false
$armClient = [pscustomobject]@{}
$armClient | Add-Member ScriptMethod SendAsync {
    param($Request, $CancellationToken)
    Assert ($Request.RequestUri.Host -eq 'management.azure.com') 'ARM transport uses the expected endpoint'
    Assert ($CancellationToken.CanBeCanceled) 'ARM transport propagates the request deadline'
    if ($script:armDelay) {
        return [Threading.Tasks.Task]::Delay([Threading.Timeout]::Infinite, $CancellationToken)
    }
    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
    $response.Content = [Net.Http.StringContent]::new('{"value":[]}')
    return [Threading.Tasks.Task]::FromResult($response)
}
$response = Invoke-ZavaArmRequest '/subscriptions/test/resources?api-version=test' -TimeoutSeconds 1
Assert ($response.StatusCode -eq 200 -and $response.Body.value -is [array]) 'ARM transport parses a successful collection'
$script:armDelay = $true
Assert-Throws { Invoke-ZavaArmRequest '/subscriptions/test/resources?api-version=test' -TimeoutSeconds 0.05 } 'canceled'

$watchAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $lab 'scripts\watch-agent.ps1'), [ref]$null, [ref]$null)
$watchFunctions = $watchAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('ConvertTo-AgentCollection', 'Get-Threads', 'Get-ThreadMessages')
}, $false)
# Load only the collection readers, not the watch script's authentication or entry point.
$watchFunctions | ForEach-Object { Invoke-Expression $_.Extent.Text }
$script:agentResponses = [Collections.Generic.Queue[object]]::new()
function Get-AgentEndpoint { return 'https://agent.example' }
function Get-AgentHeaders { return @{} }
function Invoke-RestMethod {
    param($Uri, $Headers, $MaximumRedirection, [switch]$AllowInsecureRedirect)
    Assert ($Uri -match '^https://agent\.example/api/v1/threads') 'Watch requests retain the agent endpoint'
    $response = $script:agentResponses.Dequeue()
    if ($response -is [array]) { Write-Output -NoEnumerate $response }
    else { return $response }
}

$script:agentResponses.Enqueue([pscustomobject]@{value=@()})
Assert (@(Get-Threads).Count -eq 0) 'An empty wrapped thread collection returns no threads'
$script:agentResponses.Enqueue([pscustomobject]@{value=@()})
Assert (@(Get-ThreadMessages -ThreadId 'thread-1').Count -eq 0) 'An empty wrapped message collection returns no messages'
$script:agentResponses.Enqueue([object[]]@())
Assert (@(Get-Threads).Count -eq 0) 'A bare empty thread collection returns no threads'
$script:agentResponses.Enqueue([object[]]@())
Assert (@(Get-ThreadMessages -ThreadId 'thread-1').Count -eq 0) 'A bare empty message collection returns no messages'

$script:agentResponses.Enqueue([pscustomobject]@{value=@(
    [pscustomobject]@{id='thread-2'; createdTimestamp='2026-01-02T00:00:00Z'}
    [pscustomobject]@{id='thread-1'; createdTimestamp='2026-01-01T00:00:00Z'}
)})
Assert (((Get-Threads).id -join ',') -eq 'thread-1,thread-2') 'Threads remain sorted by createdTimestamp'
$script:agentResponses.Enqueue([pscustomobject]@{value=@(
    [pscustomobject]@{id='message-2'; timeStamp='2026-01-02T00:00:00Z'}
    [pscustomobject]@{id='message-1'; timeStamp='2026-01-01T00:00:00Z'}
)})
Assert (((Get-ThreadMessages -ThreadId 'thread-1').id -join ',') -eq 'message-1,message-2') 'Messages remain sorted by timeStamp'

$script:agentResponses.Enqueue([pscustomobject]@{items=@()})
Assert-Throws { Get-Threads } 'Agent API did not return a collection\.'
$script:agentResponses.Enqueue('not-a-collection')
Assert-Throws { Get-ThreadMessages -ThreadId 'thread-1' } 'Agent API did not return a collection\.'
Assert-Throws { ConvertTo-AgentCollection -Response $null } 'Agent API did not return a collection\.'

. (Join-Path $lab 'scripts\_sre-connectors.ps1')
Assert (-not (Test-ZavaTransientArmError ([pscustomobject]@{code='AuthorizationFailed'; details=$null}))) 'Null details do not turn terminal errors into retries'
Assert (-not (Test-ZavaTransientArmError ([pscustomobject]@{code='DeploymentFailed'; details=@(
    [pscustomobject]@{code='BadGateway'}, [pscustomobject]@{code='InvalidTemplate'}
)}))) 'Mixed failures are not classified as purely transient'
$script:armResponses = [Collections.Generic.Queue[object]]::new()
$script:armCalls = [Collections.Generic.List[object]]::new()
$script:previousDeploymentPath = $null
function Invoke-ZavaArmRequest {
    param($Path, $Method = 'Get', $Body, [double]$TimeoutSeconds = 30)
    $script:armCalls.Add(@{path=$Path; method=$Method; body=$Body; timeout=$TimeoutSeconds})
    if ($script:previousDeploymentPath) {
        if ($Path -match '/connectors\?') {
            return [pscustomobject]@{StatusCode=200; Body=[pscustomobject]@{value=$existing}; Text=''}
        }
        if ($Method -eq 'Put') {
            throw [Net.Http.HttpRequestException]::new(
                [Net.Http.HttpRequestError]::NameResolutionError, 'submission never reached ARM', $null, $null)
        }
        if ($Path -eq $script:previousDeploymentPath) {
            return [pscustomobject]@{StatusCode=200; Body=(Arm-State 'Succeeded'); Text=''}
        }
        return [pscustomobject]@{StatusCode=404; Body=$null; Text='DeploymentNotFound'}
    }
    if ($script:armResponses.Count) {
        $response = $script:armResponses.Dequeue()
        if ($response -is [Exception]) { throw $response }
        return $response
    }
    if ($Method -eq 'Post' -and $Path -match '/cancel\?') { return [pscustomobject]@{StatusCode=204; Body=$null; Text=''} }
    return [pscustomobject]@{StatusCode=200; Body=[pscustomobject]@{properties=[pscustomobject]@{provisioningState='Running'}}; Text=''}
}
function Add-ArmResponse($Status, $Body) {
    $script:armResponses.Enqueue([pscustomobject]@{StatusCode=$Status; Body=$Body; Text='test response'})
}
function Arm-State($State, $ErrorDetail = $null) {
    return [pscustomobject]@{properties=[pscustomobject]@{provisioningState=$State; error=$ErrorDetail}}
}
$deployment = '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.Resources/deployments/connectors'
Add-ArmResponse 202 $null
Add-ArmResponse 200 (Arm-State 'Running')
Add-ArmResponse 200 (Arm-State 'Succeeded')
Invoke-ZavaConnectorDeployment -Template @{} -Parameters @{} -DeploymentPath $deployment -PollSeconds 0
Assert ($script:armCalls.Count -eq 3) 'ARM acceptance alone is not convergence'
Assert ($script:armCalls[0].body.properties.mode -eq 'Incremental') 'Connector deployment cannot prune unmanaged resources'

$script:armCalls.Clear()
Add-ArmResponse 202 $null
$script:armResponses.Enqueue([Threading.Tasks.TaskCanceledException]::new('poll timed out'))
$script:armResponses.Enqueue([Net.Http.HttpRequestException]::new(
    [Net.Http.HttpRequestError]::ConnectionError, 'connection unavailable', $null, $null))
Add-ArmResponse 200 (Arm-State 'Succeeded')
Invoke-ZavaConnectorDeployment @{} @{} $deployment -TimeoutSeconds 5 -PollSeconds 0
Assert (($script:armCalls.method -join ',') -eq 'Put,Get,Get,Get') 'Transient polling transport failures resume the same deployment'
Assert (@($script:armCalls | Where-Object { $_.timeout -le 0 -or $_.timeout -gt 5 }).Count -eq 0) 'Requests use the remaining deployment budget'

$script:armCalls.Clear()
Add-ArmResponse 202 $null
$script:armResponses.Enqueue([Net.Http.HttpRequestException]::new(
    [Net.Http.HttpRequestError]::SecureConnectionError, 'certificate validation failed', $null, $null))
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -PollSeconds 0 } 'certificate validation failed'
Assert (($script:armCalls.method -join ',') -eq 'Put,Get,Post') 'Terminal polling failures request cancellation rather than retrying'

$script:armCalls.Clear()
Add-ArmResponse 202 $null
$script:armResponses.Enqueue([Threading.Tasks.TaskCanceledException]::new('poll timed out'))
$script:armResponses.Enqueue([Net.Http.HttpRequestException]::new('cancellation connection failed'))
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -TimeoutSeconds 1 -PollSeconds 1 } "exceeded 1 seconds.*$([regex]::Escape($deployment))"
Assert (($script:armCalls.method -join ',') -eq 'Put,Get,Post') 'A transport timeout reaching the deadline still attempts cancellation'
Assert ($script:armCalls[-1].timeout -le 30) 'Cancellation has a separate bounded request budget'

$script:armCalls.Clear()
$script:armResponses.Enqueue([Threading.Tasks.TaskCanceledException]::new('submission response lost'))
Add-ArmResponse 200 (Arm-State 'Succeeded')
Invoke-ZavaConnectorDeployment @{} @{} $deployment -PollSeconds 0
Assert (($script:armCalls.method -join ',') -eq 'Put,Get') 'A lost submission response is polled before attempting another write'

$script:armCalls.Clear()
$script:armResponses.Enqueue([Net.Http.HttpRequestException]::new(
    [Net.Http.HttpRequestError]::SecureConnectionError, 'certificate validation failed', $null, $null))
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -PollSeconds 0 } 'certificate validation failed'
Assert (($script:armCalls.method -join ',') -eq 'Put') 'Submission certificate errors do not trigger retries or cancellation'

$script:armCalls.Clear()
Add-ArmResponse 202 $null
Add-ArmResponse 200 (Arm-State 'Failed' ([pscustomobject]@{code='DeploymentFailed'; details=@([pscustomobject]@{code='BadGateway'})}))
Add-ArmResponse 202 $null
Add-ArmResponse 200 (Arm-State 'Succeeded')
Invoke-ZavaConnectorDeployment -Template @{} -Parameters @{} -DeploymentPath $deployment -PollSeconds 0
Assert (@($script:armCalls | Where-Object method -eq 'Put').Count -eq 2) 'Transient terminal deployment failure can be retried'

$script:armCalls.Clear()
Add-ArmResponse 202 $null
Add-ArmResponse 200 (Arm-State 'Failed' ([pscustomobject]@{code='DeploymentFailed'; details=@([pscustomobject]@{code='AuthorizationFailed'})}))
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -PollSeconds 0 } 'AuthorizationFailed'
Assert (@($script:armCalls | Where-Object method -eq 'Put').Count -eq 1) 'Authorization failures do not loop'
Add-ArmResponse 403 $null
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -PollSeconds 0 } 'HTTP 403'
$script:armCalls.Clear()
foreach ($i in 1..3) { Add-ArmResponse 503 $null }
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -PollSeconds 0 } 'after 3 attempts'
Assert ($script:armCalls.Count -eq 3) 'Transient submission retries are bounded'
Add-ArmResponse 202 $null
Add-ArmResponse 200 ([pscustomobject]@{properties=[pscustomobject]@{}})
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -PollSeconds 0 } 'missing provisioningState'

$script:armCalls.Clear()
Add-ArmResponse 202 $null
Assert-Throws { Invoke-ZavaConnectorDeployment @{} @{} $deployment -TimeoutSeconds 1 -PollSeconds 1 } 'exceeded 1 seconds'
Assert ($script:armCalls[-1].method -eq 'Post' -and $script:armCalls[-1].path -match '/cancel\?') 'Timed-out deployment is explicitly canceled'

$definitions = (Get-Content -Raw (Join-Path $lab 'sre-config\agent-config.json') | ConvertFrom-Json).connectors
$existing = @($definitions | ForEach-Object {
    [pscustomobject]@{
        name=$_.name; tags=@{owner='operator'}
        properties=[pscustomobject]@{dataConnectorType=$_.properties.dataConnectorType; identity=$_.properties.identity; provisioningState='Succeeded'}
    }
})
$unmanaged = [pscustomobject]@{name='operator-connector'; properties=[pscustomobject]@{dataConnectorType='Mcp'; identity='system'}}
$existing += $unmanaged
$plan = Get-ZavaConnectorPlan (Join-Path $lab 'sre-config') $existing
Assert ($plan.Definitions.Count -eq 4 -and $plan.Tags.Count -eq 4) 'Only managed connector names/tags are included'
$existing[0].properties.identity = 'changed'
Assert-Throws { Get-ZavaConnectorPlan (Join-Path $lab 'sre-config') $existing } 'Nothing has been written'
$existing[0].properties.identity = $definitions[0].properties.identity

function az { $global:LASTEXITCODE = 0; return '{"resources":[]}' }
$script:armCalls.Clear()
Add-ArmResponse 200 ([pscustomobject]@{value=$existing})
Add-ArmResponse 202 $null
Add-ArmResponse 200 (Arm-State 'Succeeded')
Add-ArmResponse 200 ([pscustomobject]@{value=$existing})
$agentId = '/subscriptions/test/resourceGroups/rg-test/providers/Microsoft.App/agents/agent-test'
Sync-ZavaConnectors $plan 'connectors.bicep' $agentId "$agentId/ai" "$agentId/law"
$write = $script:armCalls | Where-Object method -eq 'Put'
Assert ($write.body.properties.parameters.connectorNames.value.Count -eq 4) 'Unmanaged connector is not written'
Assert ($write.body.properties.parameters.tagsByName.value['app-insights'].owner -eq 'operator') 'Existing connector tags survive'

$script:previousDeploymentPath = $write.path
$script:armCalls.Clear()
try {
    Assert-Throws { Sync-ZavaConnectors $plan 'connectors.bicep' $agentId "$agentId/changed-ai" "$agentId/law" -TimeoutSeconds 1 } 'exceeded 1 seconds'
    $currentWrite = $script:armCalls | Where-Object method -eq 'Put'
    Assert ($currentWrite.path -ne $script:previousDeploymentPath) 'An older successful invocation cannot satisfy a lost current submission'
    Assert (@($script:armCalls | Where-Object { $_.path -match '/connectors\?' }).Count -eq 1) 'Failed submission never reaches connector readback'
    Assert ($script:armCalls[-1].path -eq ($currentWrite.path -replace '\?api-version=.*', '/cancel?api-version=2022-09-01')) 'Cancellation targets only the current invocation'
} finally {
    $script:previousDeploymentPath = $null
}

$script:armCalls.Clear()
Add-ArmResponse 200 ([pscustomobject]@{value=$existing})
Add-ArmResponse 503 $null
$script:armResponses.Enqueue([Threading.Tasks.TaskCanceledException]::new('accepted submission response lost'))
Add-ArmResponse 200 (Arm-State 'Succeeded')
Add-ArmResponse 200 ([pscustomobject]@{value=$existing})
$longAgentId = $agentId -replace 'agent-test$', ('a' * 63)
Sync-ZavaConnectors $plan 'connectors.bicep' $longAgentId "$agentId/ai" "$agentId/law" -TimeoutSeconds 15
$deploymentCalls = @($script:armCalls | Where-Object { $_.path -match '/deployments/' })
$deploymentName = ($deploymentCalls[0].path -split '/')[-1] -replace '\?.*', ''
Assert ($deploymentName.Length -le 64 -and $deploymentName -cmatch '^[a-zA-Z0-9_.()-]+$') 'Caller builds an ARM-valid name even for a long agent name'
Assert (@($deploymentCalls.path | Select-Object -Unique).Count -eq 1) 'Submission retries and lost-response polling share one invocation name'
Assert (($deploymentCalls.method -join ',') -eq 'Put,Put,Get') 'Caller preserves transient retry and accepted lost-response recovery'

$script:armCalls.Clear()
Add-ArmResponse 200 ([pscustomobject]@{value=@($existing) + @([pscustomobject]@{name='concurrent-connector'})})
Assert-Throws { Sync-ZavaConnectors $plan 'connectors.bicep' $agentId "$agentId/ai" "$agentId/law" } 'changed after preflight'
Assert (@($script:armCalls | Where-Object method -eq 'Put').Count -eq 0) 'Concurrent inventory change stops before deployment'

$script:armCalls.Clear()
Add-ArmResponse 200 ([pscustomobject]@{value=$existing})
Add-ArmResponse 202 $null
Add-ArmResponse 200 (Arm-State 'Succeeded')
Add-ArmResponse 200 ([pscustomobject]@{value=@($unmanaged)})
Assert-Throws { Sync-ZavaConnectors $plan 'connectors.bicep' $agentId "$agentId/ai" "$agentId/law" } 'Connector readback failed'

. (Join-Path $lab 'scripts\_aks-helpers.ps1')
$postProvisionPath = Join-Path $lab 'scripts\post-provision.ps1'
$postProvisionAst = [Management.Automation.Language.Parser]::ParseFile(
    $postProvisionPath, [ref]$null, [ref]$null)
$pgExtensionFunction = $postProvisionAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Enable-ZavaPgStatStatements'
}, $false)
Assert ($null -ne $pgExtensionFunction) 'Post-provision defines the fixed pg_stat_statements gate'
Invoke-Expression $pgExtensionFunction.Extent.Text

$script:pgExtensionResponses = [Collections.Generic.Queue[object]]::new()
$script:pgExtensionCommands = [Collections.Generic.List[string]]::new()
function Invoke-AksCommand {
    param($ResourceGroup, $ClusterName, $Command, [switch]$Quiet)
    Assert ($ResourceGroup -eq 'rg-test' -and $ClusterName -eq 'aks-test') 'PostgreSQL extension gate retains the AKS scope'
    $script:pgExtensionCommands.Add($Command)
    return $script:pgExtensionResponses.Dequeue()
}
function Add-PgExtensionResponse([int]$ExitCode, [string]$Logs) {
    $script:pgExtensionResponses.Enqueue(
        [pscustomobject]@{exitCode=$ExitCode; logs=$Logs}
    )
}
$createExtensionCommand = "kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'"
$verifyExtensionCommand = "kubectl exec -n zava-demo deploy/zava-api -- node bin/run-sql.js 'SELECT extname FROM pg_extension ORDER BY extname'"
$validExtensionReadback = '{"command":"SELECT","rowCount":2,"rows":[{"extname":"pg_stat_statements"},{"extname":"plpgsql"}]}'

Add-PgExtensionResponse 0 '{"command":"CREATE","rowCount":null,"rows":[]}'
Add-PgExtensionResponse 0 $validExtensionReadback
Enable-ZavaPgStatStatements -ResourceGroup 'rg-test' -ClusterName 'aks-test' -Namespace 'zava-demo'
Assert (($script:pgExtensionCommands -join "`n") -eq "$createExtensionCommand`n$verifyExtensionCommand") 'Extension creation and exact verification use only fixed in-image SQL commands'
Assert ($verifyExtensionCommand -notmatch '\$') 'Extension verification avoids dollar-quoted SQL literals'

if ($IsWindows) {
    $azShimFixture = Join-Path ([IO.Path]::GetTempPath()) ("zava-az-cmd-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $azShimFixture | Out-Null
    try {
        $argvPath = Join-Path $azShimFixture 'argv.jsonl'
        @'
import json
import os
import sys

with open(os.environ["ZAVA_AZ_ARGV_PATH"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
print('{"exitCode":0,"logs":""}')
'@ | Set-Content -Encoding utf8 (Join-Path $azShimFixture 'capture_az_argv.py')
        @'
@echo off
python "%~dp0capture_az_argv.py" %*
'@ | Set-Content -Encoding ascii (Join-Path $azShimFixture 'az.cmd')
        $childScript = @'
. $env:ZAVA_AKS_HELPERS
Invoke-AksCommand -ResourceGroup 'rg-test' -ClusterName 'aks-test' -Command $env:ZAVA_AKS_COMMAND -Quiet | Out-Null
'@
        foreach ($expectedCommand in @($createExtensionCommand, $verifyExtensionCommand)) {
            $env:ZAVA_AZ_ARGV_PATH = $argvPath
            $env:ZAVA_AKS_HELPERS = Join-Path $lab 'scripts\_aks-helpers.ps1'
            $env:ZAVA_AKS_COMMAND = $expectedCommand
            $originalPath = $env:PATH
            $env:PATH = "$azShimFixture;$originalPath"
            try {
                & pwsh -NoProfile -Command $childScript
                Assert ($LASTEXITCODE -eq 0) 'Windows az.cmd shim child process succeeds without contacting Azure'
            } finally {
                $env:PATH = $originalPath
                Remove-Item Env:ZAVA_AZ_ARGV_PATH, Env:ZAVA_AKS_HELPERS, Env:ZAVA_AKS_COMMAND -ErrorAction SilentlyContinue
            }
        }
        $capturedLines = @(Get-Content $argvPath)
        Assert ($capturedLines.Count -eq 2) 'Windows az.cmd shim captures both fixed SQL invocations'
        for ($i = 0; $i -lt $capturedLines.Count; $i++) {
            $argv = @($capturedLines[$i] | ConvertFrom-Json)
            $commandPosition = [Array]::IndexOf($argv, '--command')
            Assert ($commandPosition -ge 0) 'Windows az.cmd invocation includes --command'
            Assert (@($argv | Where-Object { $_ -ceq '--command' }).Count -eq 1) 'Windows az.cmd invocation includes exactly one --command option'
            Assert ($argv[$commandPosition + 1] -ceq @($createExtensionCommand, $verifyExtensionCommand)[$i]) 'Windows az.cmd preserves one complete SQL command value after --command'
            Assert ($argv[$commandPosition + 2] -ceq '-o') 'Windows az.cmd does not split SQL into extra CLI arguments'
        }
        $verificationArgv = @($capturedLines[1] | ConvertFrom-Json)
        Assert (($verificationArgv -join "`n") -notmatch '\$') 'Windows az.cmd verification argv contains no dollar-quoted SQL literal'
    } finally {
        Remove-Item -Recurse -Force $azShimFixture
    }
}

foreach ($case in @(
    @{name='create failure'; responses=@(@{exitCode=1; logs='create denied'}); pattern='pg_stat_statements extension creation failed'},
    @{name='verification command failure'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=1; logs='verification denied'}
    ); pattern='pg_stat_statements extension verification failed'},
    @{name='absent verification'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"SELECT","rowCount":1,"rows":[{"extname":"plpgsql"}]}'}
    ); pattern='exactly one pg_stat_statements row'},
    @{name='duplicate verification'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"SELECT","rowCount":3,"rows":[{"extname":"pg_stat_statements"},{"extname":"pg_stat_statements"},{"extname":"plpgsql"}]}'}
    ); pattern='exactly one pg_stat_statements row'},
    @{name='malformed JSON'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{not-json'}
    ); pattern='expected JSON envelope'},
    @{name='malformed envelope'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='[]'}
    ); pattern='expected JSON envelope'},
    @{name='missing command'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"rowCount":2,"rows":[{"extname":"pg_stat_statements"},{"extname":"plpgsql"}]}'}
    ); pattern='command, rowCount, and rows properties'},
    @{name='wrong command case'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"select","rowCount":2,"rows":[{"extname":"pg_stat_statements"},{"extname":"plpgsql"}]}'}
    ); pattern='command must be SELECT'},
    @{name='missing rowCount'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"SELECT","rows":[{"extname":"pg_stat_statements"},{"extname":"plpgsql"}]}'}
    ); pattern='command, rowCount, and rows properties'},
    @{name='missing rows'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"SELECT","rowCount":2}'}
    ); pattern='command, rowCount, and rows properties'},
    @{name='non-array rows'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"SELECT","rowCount":1,"rows":{"extname":"pg_stat_statements"}}'}
    ); pattern='numeric rowCount matching rows'},
    @{name='non-numeric rowCount'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"SELECT","rowCount":"2","rows":[{"extname":"pg_stat_statements"},{"extname":"plpgsql"}]}'}
    ); pattern='numeric rowCount matching rows'},
    @{name='row-count mismatch'; responses=@(
        @{exitCode=0; logs='{"command":"CREATE","rowCount":null,"rows":[]}'},
        @{exitCode=0; logs='{"command":"SELECT","rowCount":1,"rows":[{"extname":"pg_stat_statements"},{"extname":"plpgsql"}]}'}
    ); pattern='numeric rowCount matching rows'}
)) {
    $script:pgExtensionCommands.Clear()
    foreach ($response in $case.responses) {
        Add-PgExtensionResponse $response.exitCode $response.logs
    }
    Assert-Throws {
        Enable-ZavaPgStatStatements -ResourceGroup 'rg-test' -ClusterName 'aks-test' -Namespace 'zava-demo'
    } $case.pattern
    Assert ($script:pgExtensionCommands.Count -eq $case.responses.Count) "$($case.name) stops at the failing extension gate"
}

$postProvision = Get-Content -Raw (Join-Path $lab 'scripts\post-provision.ps1')
$rolloutComplete = $postProvision.IndexOf("Assert-AksCommandSucceeded `$r 'Application rollout'")
$extensionStart = $postProvision.IndexOf('Write-Host "=== Step 7b: Ensuring pg_stat_statements')
$extensionCall = $postProvision.IndexOf('Enable-ZavaPgStatStatements -ResourceGroup')
$setupCall = $postProvision.IndexOf('& "$PSScriptRoot\setup-sre-agent.ps1"')
Assert ($rolloutComplete -ge 0 -and $extensionStart -gt $rolloutComplete) 'Extension provisioning starts only after API rollout succeeds'
Assert ($extensionCall -ge $extensionStart -and $setupCall -gt $extensionCall) 'Extension verification completes before SRE Agent setup'
# Run the production tail; only the cloud transport and setup entry point are stubbed.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("zava-endpoint-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$postProvision.Substring($extensionStart) | Set-Content (Join-Path $fixture 'endpoint-stage.ps1')
@'
param(
    $ResourceGroup,
    $AgentName,
    $PostgresHost,
    $PostgresDatabase,
    $SreAgentClientId,
    $SreAgentPrincipalName
)
$SetupCalls.Add(@{
    ResourceGroup=$ResourceGroup
    AgentName=$AgentName
    PostgresHost=$PostgresHost
    PostgresDatabase=$PostgresDatabase
    SreAgentClientId=$SreAgentClientId
    SreAgentPrincipalName=$SreAgentPrincipalName
})
if ($FailAgentSetup) { throw 'Agent setup failed' }
if ($AgentExitCode) { exit $AgentExitCode }
'@ | Set-Content (Join-Path $fixture 'setup-sre-agent.ps1')
$ingressState = @{
    Responses = [Collections.Generic.Queue[object]]::new()
    Calls = 0
    Output = [Collections.Generic.List[string]]::new()
}
$SetupCalls = [Collections.Generic.List[object]]::new()
$PgGateCalls = [Collections.Generic.List[object]]::new()
function Enable-ZavaPgStatStatements {
    param($ResourceGroup, $ClusterName, $Namespace)
    $PgGateCalls.Add(@{
        ResourceGroup=$ResourceGroup
        ClusterName=$ClusterName
        Namespace=$Namespace
    })
    if ($FailPgGate) { throw 'PostgreSQL extension gate failed' }
}
function Invoke-AksCommand {
    param($ResourceGroup, $ClusterName, $Command, [switch]$Quiet)
    Assert ($ResourceGroup -eq 'rg-test' -and $ClusterName -eq 'aks-test') 'Ingress lookup retains the intended AKS scope'
    Assert ($Command -match 'kubectl get svc.*ingress-nginx-controller') 'Ingress polling uses the existing Service'
    $ingressState.Calls++
    if ($ingressState.Responses.Count) { return $ingressState.Responses.Dequeue() }
    return [pscustomobject]@{exitCode=0; logs=''}
}
function Invoke-EndpointStage(
    [bool]$FailAgentSetup = $false,
    [string]$AgentName = 'agent-test',
    [int]$AgentExitCode = 0,
    [bool]$FailPgGate = $false
) {
    Set-StrictMode -Version Latest
    $RG = 'rg-test'
    $AKS_NAME = 'aks-test'
    $DB_HOST = 'zava-pg-test.postgres.database.azure.com'
    $DB_NAME = 'zava_store_test'
    $SRE_AGENT_CLIENT_ID = 'client-test'
    $SRE_AGENT_PRINCIPAL_NAME = 'id-sre-test'
    $SRE_AGENT_NAME = $AgentName
    $Namespace = 'zava-demo'
    $IngressTimeoutSeconds = 1
    function Get-AzdValue { param($Key); return $AgentName }
    function Start-Sleep { param($Seconds, $Milliseconds) }
    & (Join-Path $fixture 'endpoint-stage.ps1') 6>&1 | ForEach-Object { $ingressState.Output.Add([string]$_) }
}
try {
    foreach ($logs in @('', '<pending>', '192.0.2.10')) {
        $ingressState.Responses.Enqueue([pscustomobject]@{exitCode=0; logs=$logs})
    }
    Invoke-EndpointStage
    Assert ($PgGateCalls.Count -eq 1 -and $ingressState.Calls -eq 3 -and $SetupCalls.Count -eq 1) 'Verified extension gate precedes endpoint and agent setup'
    Assert ($SetupCalls[0].ResourceGroup -eq 'rg-test' -and $SetupCalls[0].AgentName -eq 'agent-test') 'Agent setup receives the intended target'
    Assert ($SetupCalls[0].PostgresHost -eq 'zava-pg-test.postgres.database.azure.com') 'Agent setup receives the resolved PostgreSQL host'
    Assert ($SetupCalls[0].PostgresDatabase -eq 'zava_store_test') 'Agent setup receives the resolved PostgreSQL database'
    Assert ($SetupCalls[0].SreAgentClientId -eq 'client-test') 'Agent setup receives the resolved UMI client ID'
    Assert ($SetupCalls[0].SreAgentPrincipalName -eq 'id-sre-test') 'Agent setup receives the matching UMI principal name'
    Assert (($ingressState.Output -join "`n") -match 'http://192\.0\.2\.10/') 'Endpoint output uses the assigned IP'
    Assert ($ingressState.Output[-2] -match 'Deployed Successfully') 'Success is reported only after the final setup stage'

    $SetupCalls.Clear()
    $PgGateCalls.Clear()
    $ingressState.Output.Clear()
    $ingressState.Calls = 0
    Assert-Throws { Invoke-EndpointStage -FailPgGate $true } 'PostgreSQL extension gate failed'
    Assert ($PgGateCalls.Count -eq 1 -and $ingressState.Calls -eq 0 -and $SetupCalls.Count -eq 0) 'Extension gate failure prevents endpoint and SRE setup'
    Assert (($ingressState.Output -join "`n") -notmatch 'Deployed Successfully') 'Extension gate failure cannot announce deployment success'

    $SetupCalls.Clear()
    $ingressState.Output.Clear()
    $ingressState.Calls = 0
    Assert-Throws { Invoke-EndpointStage } 'Ingress public IP.*1 seconds'
    Assert ($ingressState.Calls -gt 1 -and $SetupCalls.Count -eq 0) 'Permanently pending ingress times out before agent setup'
    Assert (($ingressState.Output -join "`n") -notmatch 'Deployed Successfully') 'Pending timeout cannot announce deployment success'

    $ingressState.Output.Clear()
    $ingressState.Calls = 0
    $ingressState.Responses.Enqueue([pscustomobject]@{exitCode=1; logs='Forbidden'})
    Assert-Throws { Invoke-EndpointStage } 'Public endpoint lookup failed: Forbidden'
    Assert ($ingressState.Calls -eq 1 -and $SetupCalls.Count -eq 0) 'A kubectl failure stops immediately rather than waiting for an IP'

    $ingressState.Responses.Enqueue([pscustomobject]@{exitCode=0; logs='192.0.2.10'})
    Assert-Throws { Invoke-EndpointStage -FailAgentSetup $true } 'Agent setup failed'
    Assert (($ingressState.Output -join "`n") -notmatch 'Deployed Successfully') 'Agent setup failure cannot announce deployment success'

    $ingressState.Responses.Enqueue([pscustomobject]@{exitCode=0; logs='192.0.2.10'})
    Assert-Throws { Invoke-EndpointStage -AgentExitCode 1 } 'SRE Agent configuration failed'
    Assert (($ingressState.Output -join "`n") -notmatch 'Deployed Successfully') 'A nonzero setup exit cannot announce deployment success'

    $SetupCalls.Clear()
    $ingressState.Responses.Enqueue([pscustomobject]@{exitCode=0; logs='not-an-address'})
    Assert-Throws { Invoke-EndpointStage } 'invalid IPv4 address'
    Assert ($SetupCalls.Count -eq 0) 'Malformed endpoint output is not treated as an assigned IP'
} catch {
    Write-Host ($ingressState.Output -join "`n")
    throw
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
Write-Host 'All readiness contracts passed.'
