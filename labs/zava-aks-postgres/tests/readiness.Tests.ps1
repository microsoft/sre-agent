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
$postProvision = Get-Content -Raw (Join-Path $lab 'scripts\post-provision.ps1')
$endpointStart = $postProvision.IndexOf('Write-Host "=== Step 8: Getting public endpoint')
Assert ($endpointStart -ge 0) 'Post-provision endpoint stage is present'
# Run the production tail; only the cloud transport and setup entry point are stubbed.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("zava-endpoint-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$postProvision.Substring($endpointStart) | Set-Content (Join-Path $fixture 'endpoint-stage.ps1')
@'
param($ResourceGroup, $AgentName)
$SetupCalls.Add(@{ResourceGroup=$ResourceGroup; AgentName=$AgentName})
if ($FailAgentSetup) { throw 'Agent setup failed' }
if ($AgentExitCode) { exit $AgentExitCode }
'@ | Set-Content (Join-Path $fixture 'setup-sre-agent.ps1')
$ingressState = @{
    Responses = [Collections.Generic.Queue[object]]::new()
    Calls = 0
    Output = [Collections.Generic.List[string]]::new()
}
$SetupCalls = [Collections.Generic.List[object]]::new()
function Invoke-AksCommand {
    param($ResourceGroup, $ClusterName, $Command, [switch]$Quiet)
    Assert ($ResourceGroup -eq 'rg-test' -and $ClusterName -eq 'aks-test') 'Ingress lookup retains the intended AKS scope'
    Assert ($Command -match 'kubectl get svc.*ingress-nginx-controller') 'Ingress polling uses the existing Service'
    $ingressState.Calls++
    if ($ingressState.Responses.Count) { return $ingressState.Responses.Dequeue() }
    return [pscustomobject]@{exitCode=0; logs=''}
}
function Invoke-EndpointStage([bool]$FailAgentSetup = $false, [string]$AgentName = 'agent-test', [int]$AgentExitCode = 0) {
    Set-StrictMode -Version Latest
    $RG = 'rg-test'
    $AKS_NAME = 'aks-test'
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
    Assert ($ingressState.Calls -eq 3 -and $SetupCalls.Count -eq 1) 'Pending ingress eventually reaches agent setup'
    Assert ($SetupCalls[0].ResourceGroup -eq 'rg-test' -and $SetupCalls[0].AgentName -eq 'agent-test') 'Agent setup receives the intended target'
    Assert (($ingressState.Output -join "`n") -match 'http://192\.0\.2\.10/') 'Endpoint output uses the assigned IP'
    Assert ($ingressState.Output[-2] -match 'Deployed Successfully') 'Success is reported only after the final setup stage'

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
