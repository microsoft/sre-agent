#Requires -Version 7.4
# Dependency-free tests of the production renderer/synchronizer, with in-memory APIs.
$ErrorActionPreference = 'Stop'
$lab = Split-Path $PSScriptRoot -Parent
$root = Join-Path $lab 'sre-config'
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
function Copy-Json($Value) { ConvertFrom-Json -InputObject ($Value | ConvertTo-Json -Depth 50) }
function Compare-Equal($Expected, $Actual, [string]$Label) {
    $diff = [Collections.Generic.List[string]]::new()
    Compare-ExpectedProperties $Expected $Actual $Label $diff
    Assert ($diff.Count -eq 0) ($diff -join '; ')
}
function az { throw 'Unexpected Azure CLI call in an offline test.' }
function azd { throw 'Unexpected azd call in an offline test.' }
function Start-Sleep { param($Seconds) }

$configuration = Get-ZavaConfiguration $root 'rg-offline'
$render = & (Join-Path $lab 'scripts\setup-sre-agent.ps1') -ResourceGroup rg-offline -RenderOnly | ConvertFrom-Json
Assert ($render.Resources.Count -eq 15) 'Offline setup entry point renders 9 skills, 2 agents, 4 plans'
Assert ($render.EvidenceToolMode -ceq 'SkillOwned') 'Target ownership mode is explicit in render output'
Assert ($render.CustomInstructions.Contains('Do not route around the restriction')) 'Parent remediation must respect blocked actions'
$skills = @{}
foreach ($r in $configuration.Resources | Where-Object Kind -eq 'skills') { $skills[$r.Name] = $r.Body.properties }
$agents = @($configuration.Resources | Where-Object Kind -eq 'agents')
$monitor = @('system-mcp-monitor_monitor_resource_log_query', 'system-mcp-monitor_monitor_metrics_query')
foreach ($name in @('zava-application-evidence', 'zava-database-evidence')) {
    Compare-Equal @{ tools = $monitor } $skills[$name] "$name persisted tool metadata"
    Assert ($skills[$name].description.Length -gt 20) 'Skill discovery description'
    Assert ($skills[$name].skillContent -notmatch '@@|managed identity|Cluster Admin|Resource Group `rg-offline`') 'No privileged shared context in evidence skills'
    Assert ($skills[$name].skillContent -notmatch '(?m)^tools:') 'No competing frontmatter tools'
    foreach ($field in @('Scope', 'Observation', 'Source', 'Status', 'Interpretation', 'Gaps', 'Follow-up')) {
        Assert ($skills[$name].skillContent.Contains("**$field**")) "$name evidence output includes $field"
    }
}
Assert ($skills['zava-investigation-coordination'].tools.Count -eq 0) 'Coordinator owns no cloud tools'
Assert ($skills['application-incidents'].skillContent.Contains('rg-offline')) 'Legacy shared context still renders'
foreach ($name in @('database-incidents', 'application-incidents', 'performance-incidents')) {
    Assert ($skills[$name].skillContent.Contains("cloud_RoleName == 'zava-api'")) "$name includes classic telemetry role scoping"
    Assert ($skills[$name].skillContent.Contains("AppRoleName == 'zava-api'")) "$name includes workspace telemetry role scoping"
    Assert ($skills[$name].skillContent.Contains('pass the subscription ID explicitly')) "$name includes explicit Monitor subscription"
}
Assert ($skills['database-incidents'].skillContent.Contains('monitorCondition == Resolved')) 'Database runbook distinguishes condition from alert state'
Assert ($skills['database-incidents'].skillContent.Contains('stop retrying it')) 'Blocked alert closure must not become an unbounded retry loop'
Assert (($render | ConvertTo-Json -Depth 50) -notmatch '@@|preToolUseScriptFile|propertiesFile') 'No loader tokens/fields in API bodies'

$hookText = [IO.File]::ReadAllText((Join-Path $root 'hooks\readonly-evidence.py')).Replace("`r", '').Trim()
foreach ($agent in $agents) {
    $p = $agent.Body.properties
    Assert ($agent.Body.type -ceq 'ExtendedAgent') 'Agent resource envelope type'
    Assert ($agent.Path -ceq "/api/v2/extendedAgent/agents/$($agent.Name)") 'Supported agent API route'
    Assert ($p.handoffDescription.Length -gt 20) 'Named agent discoverability'
    Assert ($p.allowedSkills.Count -eq 1) 'Nonempty narrow skill scope'
    Compare-Equal @{ tools = @('ReadFile'); mcpTools = @(); commonTools = @() } $p 'Explicit useful read base'
    Assert ($p.instructions.Contains($p.allowedSkills[0]) -and $p.instructions.Contains('read_skill_file')) 'Child reads own domain skill'
    Assert ($p.hooks.Count -eq 1 -and $p.hooks.PreToolUse.Count -eq 1) 'Only child PreToolUse hook'
    Compare-Equal @{ type = 'command'; matcher = '(?s:.*)'; timeout = 30; failMode = 'block'; script = $hookText } $p.hooks.PreToolUse[0] 'Exact shared guard'
}
$fallback = Get-ZavaConfiguration $root 'rg-offline' 'ExplicitAgent'
foreach ($agent in $fallback.Resources | Where-Object Kind -eq 'agents') {
    Compare-Equal @{ tools = @('ReadFile'); mcpTools = $monitor } $agent.Body.properties 'Labelled explicit-agent fallback'
}
# Freeze every response-plan property, not just route names/counts.
$routes = @(
    @('zava-database', 'postgres', 'autonomous', 3),
    @('zava-performance', 'query-slow', 'autonomous', 3),
    @('zava-application', 'http-5xx', 'autonomous', 3),
    @('zava-unknown', 'Zava', 'review', 2)
)
$filters = @($configuration.Resources | Where-Object Kind -eq 'incidentFilters')
Assert ($filters.Count -eq 4) 'Exactly the four original response plans'
foreach ($route in $routes) {
    $expected = @{
        incidentPlatform = 'AzMonitor'; impactedService = ''; priorities = @('Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4')
        incidentType = ''; alertId = ''; titleContains = $route[1]; titleContainsAll = @(); titleContainsAny = @()
        titleNotContains = @(if ($route[0] -eq 'zava-unknown') { 'postgres'; 'query-slow'; 'http-5xx' })
        agentMode = $route[2]; handlingAgent = 'meta_agent'; handlingAgents = $null; owningTeamId = ''; owningTeamIds = @()
        maxAutomatedInvestigationAttempts = $route[3]; mergeEnabled = $false; mergeWindowHours = 3; isEnabled = $true
        icmFilterSettings = $null; azMonitorFilterSettings = @{ targetResourceType = ''; targetResource = '' }
    }
    $actual = ($filters | Where-Object Name -eq $route[0]).Body.properties
    Compare-Equal $expected $actual $route[0]
    Assert ($expected.Count -eq $actual.Count) 'No extra response-plan properties'
}
foreach ($name in @('application-incidents', 'performance-incidents')) {
    Assert ('RunKubectlWriteCommand' -cin $skills[$name].tools) "$name keeps authorized writes"
    Assert ($skills[$name].skillContent.Contains('## Permitted autonomous actions')) "$name retains remediation"
    Assert ($skills[$name].skillContent.Contains('## Verify')) "$name retains recovery verification"
    Assert ($skills[$name].skillContent.Contains('zava-investigation-coordination')) "$name routes overlapping symptoms to the coordinator"
}
Assert ($skills['application-incidents'].skillContent.Contains('kubectl rollout undo deployment/zava-api -n zava-demo')) 'Parent rollout undo preserved'
Assert ($skills['application-incidents'].skillContent.Contains('Check each affected route')) 'Application recovery cannot rely on fleet-wide success rates'
Assert ($skills['application-incidents'].skillContent.Contains('pod-template and configuration differences')) 'Application diagnosis inspects the actual deployment change'
Assert ($skills['performance-incidents'].skillContent.Contains('CREATE INDEX CONCURRENTLY IF NOT EXISTS')) 'Parent index remediation preserved'
Assert ($skills['performance-incidents'].skillContent.Contains('ANALYZE`, `REINDEX CONCURRENTLY')) 'Parent statistics/reindex preserved'
Assert ($skills['performance-incidents'].skillContent.Contains('`ORDER BY`, `LIMIT`, and `OFFSET`')) 'Performance diagnosis retains the full query shape'
Assert ($skills['performance-incidents'].skillContent.Contains('comparable load')) 'Performance verification compares equivalent workload'
Assert ($skills['performance-incidents'].skillContent.Contains('incomplete telemetry bucket')) 'Partial buckets cannot establish recovery'

# Canonical comparison ignores server fields, property/set ordering and CRLF,
# but catches changed tool selections, script contents and extra active hooks.
$actual = Copy-Json $agents[0].Body.properties
$actual | Add-Member NoteProperty createdAt 'server-generated'
$actual.instructions = $actual.instructions.Replace("`n", "`r`n")
$actual.hooks.PreToolUse[0].script = $hookText.Replace("`n", "`r`n") + "`r`n"
$actual.hooks.PreToolUse[0].type = 'Command'
$actual.hooks.PreToolUse[0].failMode = 'Block'
$actual.hooks.PreToolUse[0] | Add-Member NoteProperty command $null
Compare-Equal $agents[0].Body.properties $actual 'Normalized readback'
$actual.hooks.PreToolUse[0].script += "`n# changed"
$diff = [Collections.Generic.List[string]]::new()
Compare-ExpectedProperties $agents[0].Body.properties $actual 'agent' $diff
Assert ($diff.Count -eq 1 -and $diff[0] -eq 'agent.hooks differs') 'Changed guard detected'
foreach ($field in @('matcher', 'tools')) {
    $actual = Copy-Json $agents[0].Body.properties
    if ($field -eq 'matcher') { $actual.hooks.PreToolUse[0].matcher += ' ' }
    else { $actual.tools = @('ReadFile ') }
    $diff = [Collections.Generic.List[string]]::new()
    Compare-ExpectedProperties $agents[0].Body.properties $actual 'agent' $diff
    Assert ($diff.Count -gt 0) "Whitespace in $field is material, not text normalization"
}
$actual = Copy-Json $agents[0].Body.properties
$actual.hooks | Add-Member NoteProperty PostToolUse @(@{ type = 'command'; script = 'different' })
$diff = [Collections.Generic.List[string]]::new()
Compare-ExpectedProperties $agents[0].Body.properties $actual 'agent' $diff
Assert ($diff.Count -eq 1) 'Unexpected active hook event is drift'

# Exercise the setup script's real collection decoder without starting setup.
$setupAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $lab 'scripts\setup-sre-agent.ps1'), [ref]$null, [ref]$null)
foreach ($definition in $setupAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Get-DataPlaneJson', 'Get-DataPlaneCollection', 'Invoke-DataPlaneWrite')
}, $true)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$agentEndpoint = 'https://offline.invalid'
$script:responseJson = '[]'
$script:responseSuccess = $true
$client = [pscustomobject]@{}
$client | Add-Member ScriptMethod GetAsync {
    param($Uri)
    $content = [pscustomobject]@{}
    $content | Add-Member ScriptMethod ReadAsStringAsync { return [pscustomobject]@{ Result = $script:responseJson } }
    $response = [pscustomobject]@{ IsSuccessStatusCode = $script:responseSuccess; StatusCode = 403; Content = $content }
    $response | Add-Member ScriptMethod Dispose {}
    return [pscustomobject]@{ Result = $response }
}
Assert (@(Get-DataPlaneCollection '/api/v2/extendedAgent/agents').Count -eq 0) 'Empty raw array is a valid inventory'
$script:responseJson = '{"value":[]}'
Assert (@(Get-DataPlaneCollection '/api/v2/extendedAgent/agents').Count -eq 0) 'Empty envelope is a valid inventory'
& {
    Set-StrictMode -Version Latest
    Assert (@(Get-DataPlaneCollection '/api/v2/extendedAgent/agents').Count -eq 0) 'Collection without nextLink works under post-provision strict mode'
}
$script:responseJson = '{"value":[{"name":"first"},{"name":"second"}]}'
Assert (@(Get-DataPlaneCollection '/api/v2/extendedAgent/agents').Count -eq 2) 'Collection envelope decoded'
$script:responseJson = '{"value":[{"name":"first"}],"nextLink":"unread-page"}'
Assert-Throws { Get-DataPlaneCollection '/api/v2/extendedAgent/agents' } 'partial configuration comparison'
$script:responseJson = '{}'
Assert-Throws { Get-DataPlaneCollection '/api/v2/extendedAgent/agents' } 'did not return a resource collection'
$script:responseSuccess = $false
Assert-Throws { Get-DataPlaneCollection '/api/v2/extendedAgent/agents' } 'HTTP 403'
$script:responseSuccess = $true
$client | Add-Member ScriptMethod PutAsync {
    param($Uri, $Content)
    $script:lastMethod = 'Put'
    return $this.GetAsync($Uri)
}
$client | Add-Member ScriptMethod PatchAsync {
    param($Uri, $Content)
    $script:lastMethod = 'Patch'
    return $this.GetAsync($Uri)
}
foreach ($method in @('Put', 'Patch')) {
    Assert (Invoke-DataPlaneWrite -Path '/api/v2/extendedAgent/agents/example' -Body @{} -Label 'transport' -Method $method) 'Write succeeds'
    Assert ($script:lastMethod -ceq $method) 'HTTP method reaches the selected transport'
}
$script:responseSuccess = $false
Assert (-not (Invoke-DataPlaneWrite -Path '/api/v2/extendedAgent/agents/example' -Body @{} -Label 'transport' -Method Patch)) 'Failed PATCH has no PUT fallback'
Assert ($script:lastMethod -ceq 'Patch') 'Failed PATCH retains the requested method'

# Mock only transport; exercise the production plan/apply/readback functions.
$script:remote = @{ skills = @(); agents = @(); incidentFilters = @() }
$script:writes = [Collections.Generic.List[object]]::new()
$script:acceptWithoutPersisting = $false
$script:failWrite = $false
function Get-DataPlaneCollection([string]$Path) { return @($script:remote[($Path -split '/')[-1]]) }
function Invoke-DataPlaneWrite($Path, $Body, $Label, $MaxAttempts, $Method = 'Put') {
    $script:writes.Add(@{ path = $Path; body = Copy-Json $Body; method = $Method })
    if ($script:failWrite) { return $false }
    if (-not $script:acceptWithoutPersisting) {
        $kind = ($Path -split '/')[-2]
        $saved = @($script:remote[$kind] | Where-Object name -ceq $Body.name)
        $replacement = Copy-Json $Body
        if ($Method -eq 'Patch') {
            Assert ($saved.Count -eq 1) 'PATCH requires an existing resource'
            foreach ($property in $saved[0].properties.PSObject.Properties) {
                if (-not $replacement.properties.PSObject.Properties[$property.Name]) {
                    $replacement.properties | Add-Member NoteProperty $property.Name $property.Value
                }
            }
        }
        $script:remote[$kind] = @($script:remote[$kind] | Where-Object name -cne $Body.name) + @($replacement)
    }
    return $true
}
$unmanaged = @{ name = 'operator-agent'; type = 'ExtendedAgent'; tags = @('keep'); properties = @{ instructions = 'untouched' } }
$script:remote.agents = @(Copy-Json $unmanaged)
$plan = New-ZavaSyncPlan $configuration $script:remote ''
Assert-ZavaUpdateApproved $plan
foreach ($kind in @('skills', 'agents', 'incidentFilters')) { Sync-ZavaResources $plan $kind }
Assert ($script:writes.Count -eq 15) 'First apply writes exactly managed objects'
Assert (@($script:writes | Where-Object method -ne 'Put').Count -eq 0) 'New resources use PUT'
Compare-Equal $unmanaged $script:remote.agents[0] 'Unmanaged agent untouched'
$plan = New-ZavaSyncPlan $configuration $script:remote $configuration.CustomInstructions
Assert (@($plan.Items | Where-Object Action -ne 'skip').Count -eq 0) 'Second apply is a no-op'
Assert (-not $plan.InstructionsChanged) 'Instructions no-op'
foreach ($kind in @('skills', 'agents', 'incidentFilters')) { Sync-ZavaResources $plan $kind }
Assert ($script:writes.Count -eq 15) 'No extra writes on reapply'

$savedApp = $script:remote.agents | Where-Object name -eq 'app-investigator'
$savedApp.properties.instructions = 'operator-edited instructions'
$savedApp.tags = @('operator-tag')
$savedApp.properties | Add-Member NoteProperty temperature 0.2
$savedApp.properties | Add-Member NoteProperty llmModelName 'operator-selected-model'
$savedApp.properties | Add-Member NoteProperty enableSkills $true
$plan = New-ZavaSyncPlan $configuration $script:remote 'operator global instructions'
Assert-Throws { Assert-ZavaUpdateApproved $plan } 'Nothing has been written'
Assert ($script:writes.Count -eq 15) 'Preflight drift refusal has no writes'
Assert-ZavaUpdateApproved $plan -UpdateExisting
$privateTemp = Join-Path ([IO.Path]::GetTempPath()) ("zava-config-test-" + [guid]::NewGuid().ToString('N'))
try {
    $snapshot = Save-ZavaSnapshot $plan $privateTemp '/subscriptions/offline/resourceGroups/rg-offline/providers/Microsoft.App/agents/offline'
    $previous = Get-Content -Raw $snapshot | ConvertFrom-Json
    Assert ($previous.customInstructions.instructions -ceq 'operator global instructions') 'Rollback includes previous global instructions'
    $priorApp = $previous.resources | Where-Object path -like '*/agents/app-investigator'
    Assert ($priorApp.previous.properties.instructions -ceq 'operator-edited instructions') 'Rollback includes previous agent'
    Assert (@($previous.resources | Where-Object path -like '*/operator-agent').Count -eq 0) 'Snapshot excludes unmanaged objects'
    Sync-ZavaResources $plan 'agents'
    $savedApp = $script:remote.agents | Where-Object name -eq 'app-investigator'
    Assert ($savedApp.tags[0] -ceq 'operator-tag') 'Operator tags preserved'
    Compare-Equal @{ temperature = 0.2; llmModelName = 'operator-selected-model'; enableSkills = $true } $savedApp.properties 'Unowned agent settings preserved'
    Assert ($script:writes[-1].method -eq 'Patch') 'Existing agents use partial updates'
    Assert (-not $script:writes[-1].body.properties.PSObject.Properties['llmModelName']) 'Partial update does not send operator settings'
} finally {
    if (Test-Path $privateTemp) { Remove-Item -LiteralPath $privateTemp -Recurse -Force }
}
Assert-Throws { Save-ZavaSnapshot $plan (Join-Path $root 'snapshots') 'offline' } 'outside a Git checkout'

$savedApp.properties.instructions = 'first drift'
$plan = New-ZavaSyncPlan $configuration $script:remote $configuration.CustomInstructions
$script:remote.agents = @(Copy-Json $script:remote.agents)
$savedApp = $script:remote.agents | Where-Object name -eq 'app-investigator'
$savedApp.properties.instructions = 'concurrent edit'
Assert-Throws { Sync-ZavaResources $plan 'agents' } 'changed after preflight'
$plan = New-ZavaSyncPlan $configuration $script:remote $configuration.CustomInstructions
$script:failWrite = $true
Assert-Throws { Sync-ZavaResources $plan 'agents' } 'Failed to synchronize'
$script:failWrite = $false
$script:acceptWithoutPersisting = $true
Assert-Throws { Sync-ZavaResources $plan 'agents' } 'readback did not converge'
$script:acceptWithoutPersisting = $false
Sync-ZavaResources $plan 'agents'

# Render invalid fixtures using the same renderer, never editing the checked-in source.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("zava-render-test-" + [guid]::NewGuid().ToString('N'))
try {
    Copy-Item -LiteralPath $root -Destination $fixture -Recurse
    $appPath = Join-Path $fixture 'agents\app-investigator.json'
    $original = [IO.File]::ReadAllText($appPath)
    $p = $original | ConvertFrom-Json -AsHashtable
    $p.allowedSkills = @('self_manual')
    $p | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $appPath
    $coreConfig = Get-ZavaConfiguration $fixture 'rg-test'
    $coreAgent = ($coreConfig.Resources | Where-Object Name -eq 'app-investigator').Body.properties
    Compare-Equal @{ tools = @('ReadFile'); mcpTools = @(); allowedSkills = @('self_manual') } $coreAgent 'Renderer supports nonempty core control'
    foreach ($change in @(
        @{ field = 'tools'; value = @(); error = 'at least one entry' },
        @{ field = 'tools'; value = @('ReadFile '); error = 'whitespace-padded' },
        @{ field = 'allowedSkills'; value = @(); error = 'at least one entry' },
        @{ field = 'allowedSkills'; value = @('absent-skill'); error = 'Unknown selected skill' },
        @{ field = 'handoffDescription'; value = ''; error = 'empty' },
        @{ field = 'agentType'; value = 'Autonomous'; error = 'Unsupported lab agent property' },
        @{ field = 'mcpTools'; value = $monitor; error = 'explicit ReadFile base' }
    )) {
        $p = $original | ConvertFrom-Json -AsHashtable
        $p[$change.field] = $change.value
        $p | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $appPath
        Assert-Throws { Get-ZavaConfiguration $fixture 'rg-test' } $change.error
    }
    $original | Set-Content -LiteralPath $appPath
    '@@SHARED@@' | Set-Content (Join-Path $fixture 'skills\zava-application-evidence.md')
    Assert-Throws { Get-ZavaConfiguration $fixture 'rg-test' } 'Shared context is not permitted'
    '@@UNRESOLVED@@' | Set-Content (Join-Path $fixture 'skills\zava-application-evidence.md')
    Assert-Throws { Get-ZavaConfiguration $fixture 'rg-test' } 'unresolved configuration placeholder'
    Assert-Throws { Read-ZavaConfigText $fixture '..\outside.md' 'rg-test' } 'must stay within'
} finally {
    if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

. (Join-Path $lab 'scripts\_aks-helpers.ps1')
& {
    $script:telemetryExit = 0
    $script:telemetryOutput = '[{"n":"12"}]'
    $script:workspaceOutput = 'workspace-id'
    function az {
        $global:LASTEXITCODE = 0
        if (($args -join ' ') -match 'workspace list') { return $script:workspaceOutput }
        $global:LASTEXITCODE = $script:telemetryExit
        return $script:telemetryOutput
    }
    Assert-ZavaRequestTelemetry -ResourceGroup rg-test
    $script:telemetryExit = 1
    $script:telemetryOutput = 'Connection failed'
    Assert-Throws { Assert-ZavaRequestTelemetry rg-test } 'request count is unknown'
    $script:telemetryExit = 0
    $script:telemetryOutput = '[{"n":"0"}]'
    Assert-Throws { Assert-ZavaRequestTelemetry rg-test } 'No AppRequests'
    $script:telemetryOutput = '[{"unexpected":12}]'
    Assert-Throws { Assert-ZavaRequestTelemetry rg-test } 'invalid request count'
    $script:workspaceOutput = ''
    Assert-Throws { Assert-ZavaRequestTelemetry rg-test } 'Could not resolve'
    $global:LASTEXITCODE = 0
}
$script:accessAttempts = 0
$script:accessReadyAfter = 2
function Invoke-AksCommand($ResourceGroup, $ClusterName, $Command, [switch]$Quiet) {
    Assert ($Command -ceq "kubectl get namespaces -o name >/dev/null && kubectl auth can-i create deployments.apps -n zava-demo") 'Readiness checks concrete permissions, not version or wildcard access reviews'
    $script:accessAttempts++
    if ($script:accessAttempts -lt $script:accessReadyAfter) { return [pscustomobject]@{ exitCode = 1; logs = 'no' } }
    return [pscustomobject]@{ exitCode = 0; logs = "yes`n" }
}
Wait-AksOperatorAccess 'rg-test' 'aks-test' -MaxAttempts 3 -DelaySeconds 0
Assert ($script:accessAttempts -eq 2) 'AKS waits for role propagation'
$script:accessAttempts = 0
$script:accessReadyAfter = 10
Assert-Throws { Wait-AksOperatorAccess 'rg-test' 'aks-test' -MaxAttempts 2 -DelaySeconds 0 } 'access did not become ready'
Assert-Throws { Assert-AksCommandSucceeded ([pscustomobject]@{exitCode=1; logs='Forbidden'}) 'Apply' } 'Apply failed: Forbidden'
Assert-Throws { Assert-AksCommandSucceeded $null 'Apply' } 'No command result'
Assert-AksCommandSucceeded ([pscustomobject]@{exitCode=0; logs='ready'}) 'Apply'

& {
    $global:ZavaCleanupTestState = @{
        Commands = [Collections.Generic.List[string]]::new()
        HasFault = $false
        UndoFails = $false
    }
    function az {
        $global:LASTEXITCODE = 0
        $commandIndex = [array]::IndexOf($args, '--command')
        Assert ($commandIndex -ge 0) 'Cleanup uses the existing AKS command helper'
        $command = [string]$args[$commandIndex + 1]
        $global:ZavaCleanupTestState.Commands.Add($command)
        if ($command -like 'kubectl get deployment*') {
            $variables = @()
            if ($global:ZavaCleanupTestState.HasFault) { $variables = @(@{ name = 'FAULT_INJECT'; value = '500' }) }
            $deployment = @{ spec = @{ template = @{ spec = @{ containers = @(@{ env = $variables }) } } } }
            return @{ exitCode = 0; logs = ($deployment | ConvertTo-Json -Depth 10 -Compress) } | ConvertTo-Json -Compress
        }
        if ($command -like 'kubectl rollout undo*') {
            return @{ exitCode = $(if ($global:ZavaCleanupTestState.UndoFails) { 1 } else { 0 }); logs = 'rollback result' } | ConvertTo-Json -Compress
        }
        Assert ($command -like 'kubectl set env*FAULT_INJECT-*') 'Cleanup changes only the fault flag after rollback'
        return '{"exitCode":0,"logs":"fault cleared"}'
    }
    $cleanup = Join-Path $lab '.github\skills\running-demo\scripts\fix-bad-deploy.ps1'
    & $cleanup -ResourceGroup rg-test -ClusterName aks-test
    Assert ($global:ZavaCleanupTestState.Commands.Count -eq 1) 'Already-recovered cleanup must not roll back into the bad revision'
    $global:ZavaCleanupTestState.Commands.Clear()
    $global:ZavaCleanupTestState.HasFault = $true
    & $cleanup -ResourceGroup rg-test -ClusterName aks-test
    Assert ($global:ZavaCleanupTestState.Commands.Count -eq 3) 'Fault cleanup inspects, rolls back, and clears the flag'
    Assert ($global:ZavaCleanupTestState.Commands[1].Contains(' && ')) 'Rollback failure cannot be hidden by rollout status'
    $global:ZavaCleanupTestState.Commands.Clear()
    $global:ZavaCleanupTestState.UndoFails = $true
    Assert-Throws { & $cleanup -ResourceGroup rg-test -ClusterName aks-test } 'rollout undo / rollout status failed'
    Assert ($global:ZavaCleanupTestState.Commands.Count -eq 2) 'Failed rollback stops before declaring cleanup success'
    Remove-Variable ZavaCleanupTestState -Scope Global
    $global:LASTEXITCODE = 0
}

foreach ($file in Get-ChildItem (Join-Path $lab 'scripts') -Filter '*.ps1') {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    Assert (-not $errors) "PowerShell syntax: $($file.Name)"
}
Write-Host 'All configuration contracts passed.'
