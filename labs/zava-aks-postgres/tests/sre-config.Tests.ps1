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
function az {
    $global:ZavaTestAzCalls++
    throw 'Reached Azure CLI after environment resolution.'
}
$global:ZavaTestAzCalls = 0
$global:ZavaTestAzdCalls = 0
function azd {
    $global:ZavaTestAzdCalls++
    @(
        'RESOURCE_GROUP="rg-from-azd"'
        'SRE_AGENT_NAME="agent-from-azd"'
        'DB_HOST="zava-pg-from-azd.postgres.database.azure.com"'
        'DB_NAME="zava_store"'
        'SRE_AGENT_CLIENT_ID="client-from-azd"'
        'SRE_AGENT_IDENTITY_NAME="identity-from-azd"'
    )
}
function Start-Sleep { param($Seconds) }

$offlinePostgres = @{
    DB_HOST = 'zava-pg-offline.postgres.database.azure.com'
    DB_NAME = 'zava_store'
    SRE_AGENT_CLIENT_ID = 'offline-client-id'
    SRE_AGENT_PRINCIPAL_NAME = 'sre-agent-zava'
}
$configuration = Get-ZavaConfiguration $root 'rg-offline' 'SkillOwned' $offlinePostgres
$render = & (Join-Path $lab 'scripts\setup-sre-agent.ps1') `
    -ResourceGroup rg-offline `
    -PostgresHost $offlinePostgres.DB_HOST `
    -PostgresDatabase $offlinePostgres.DB_NAME `
    -SreAgentClientId $offlinePostgres.SRE_AGENT_CLIENT_ID `
    -SreAgentPrincipalName $offlinePostgres.SRE_AGENT_PRINCIPAL_NAME `
    -RenderOnly | ConvertFrom-Json
Assert ($render.Resources.Count -eq 17) 'Offline setup entry point renders 2 tools, 9 skills, 2 agents, 4 plans'
Assert ($render.EvidenceToolMode -ceq 'SkillOwned') 'Target ownership mode is explicit in render output'
Assert ($render.CustomInstructions.Contains('Do not route around the restriction')) 'Parent remediation must respect blocked actions'
Assert ($global:ZavaTestAzdCalls -eq 0) 'Offline render does not load azd environment values'
Assert ($global:ZavaTestAzCalls -eq 0) 'Offline render does not call Azure CLI'

$setupPath = Join-Path $lab 'scripts\setup-sre-agent.ps1'
$setupText = [IO.File]::ReadAllText($setupPath)
Assert ($setupText.Contains("if (-not `$ResourceGroup) { `$ResourceGroup = `$azdEnv['RESOURCE_GROUP'] }")) 'Explicit resource group takes precedence over azd'
Assert ($setupText.Contains("if (-not `$AgentName) { `$AgentName = `$azdEnv['SRE_AGENT_NAME'] }")) 'Explicit agent name takes precedence over azd'

$setupAst = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$null, [ref]$null)
$resolverNames = @(
    'Get-ZavaSinglePostgresHost',
    'Get-ZavaAgentIdentityResourceId',
    'Get-ZavaManagedIdentityPair',
    'Resolve-ZavaPostgresConfiguration'
)
$resolverDefinitions = @($setupAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in $resolverNames
}, $false))
Assert ($resolverDefinitions.Count -eq $resolverNames.Count) 'Setup exposes the PostgreSQL/identity recovery helpers'
$resolverDefinitions | ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$script:discovery = @{
    PostgresHosts = @('zava-pg-discovered.postgres.database.azure.com')
    Agent = [pscustomobject]@{
        properties = [pscustomobject]@{
            actionConfiguration = [pscustomobject]@{
                identity = '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-action'
            }
        }
        identity = [pscustomobject]@{
            userAssignedIdentities = [pscustomobject]@{
                '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-action' = [pscustomobject]@{}
            }
        }
    }
    Identities = @{
        '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-action' = @{
            name = 'id-sre-action'
            clientId = 'client-sre-action'
        }
    }
    Calls = [Collections.Generic.List[string]]::new()
}
function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    $script:discovery.Calls.Add($command)
    if ($command -match '^postgres flexible-server list ') {
        return ConvertTo-Json -InputObject @($script:discovery.PostgresHosts) -Compress
    }
    if ($command -match '^resource show .*--resource-type Microsoft\.App/agents ') {
        return ConvertTo-Json -InputObject $script:discovery.Agent -Depth 20 -Compress
    }
    if ($command -match '^identity show --ids ([^ ]+) ') {
        $identity = $script:discovery.Identities[$Matches[1]]
        if (-not $identity) { throw "Unexpected identity lookup: $($Matches[1])" }
        return ConvertTo-Json -InputObject $identity -Compress
    }
    throw "Unexpected Azure CLI call: $command"
}
function Reset-Discovery {
    $script:discovery.PostgresHosts = @('zava-pg-discovered.postgres.database.azure.com')
    $script:discovery.Agent.properties.actionConfiguration.identity =
        '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-action'
    $script:discovery.Agent.identity.userAssignedIdentities = [pscustomobject]@{
        '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-action' = [pscustomobject]@{}
    }
    $script:discovery.Calls.Clear()
}

$resolved = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup rg-explicit -AgentName agent-explicit -AzdEnvironment @{}
Compare-Equal @{
    DB_HOST = 'zava-pg-discovered.postgres.database.azure.com'
    DB_NAME = 'zava_store'
    SRE_AGENT_CLIENT_ID = 'client-sre-action'
    SRE_AGENT_PRINCIPAL_NAME = 'id-sre-action'
} $resolved 'Explicit RG/agent recovery discovers the PostgreSQL server and action UMI'
Assert (@($script:discovery.Calls | Where-Object { $_ -match '^postgres flexible-server list ' }).Count -eq 1) 'Recovery lists PostgreSQL servers once'
Assert (@($script:discovery.Calls | Where-Object { $_ -match '^identity show ' }).Count -eq 1) 'Recovery reads the selected UMI once'

Reset-Discovery
$script:discovery.Agent.identity.userAssignedIdentities = [pscustomobject]@{
    '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-sre-action' = [pscustomobject]@{}
    '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-not-action' = [pscustomobject]@{}
}
$resolved = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup rg-explicit -AgentName agent-explicit `
    -PostgresHost explicit.postgres.database.azure.com -AzdEnvironment @{}
Assert ($resolved.SRE_AGENT_PRINCIPAL_NAME -ceq 'id-sre-action') 'Action identity takes precedence over other attached UMIs'

Reset-Discovery
$resolved = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup rg-explicit -AgentName separate-agent-name `
    -PostgresHost explicit.postgres.database.azure.com `
    -SreAgentClientId client-sre-action -AzdEnvironment @{}
Assert ($resolved.SRE_AGENT_PRINCIPAL_NAME -ceq 'id-sre-action') 'A supplied client ID resolves the matching UMI name'
Assert ($resolved.SRE_AGENT_PRINCIPAL_NAME -cne 'separate-agent-name') 'The agent resource name never substitutes for the UMI principal'
Assert (@($script:discovery.Calls | Where-Object { $_ -match '^postgres flexible-server list ' }).Count -eq 0) 'Explicit PostgreSQL host skips server discovery'

Reset-Discovery
$resolved = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup rg-explicit -AgentName agent-explicit `
    -PostgresHost explicit.postgres.database.azure.com -PostgresDatabase explicit_db `
    -SreAgentClientId client-sre-action -SreAgentPrincipalName id-sre-action `
    -AzdEnvironment @{
        DB_NAME = 'azd_db'
        SRE_AGENT_CLIENT_ID = 'stale-azd-client'
        SRE_AGENT_IDENTITY_NAME = 'stale-azd-name'
    }
Assert ($resolved.DB_NAME -ceq 'explicit_db') 'Explicit database name takes precedence over azd'
Assert ($resolved.SRE_AGENT_CLIENT_ID -ceq 'client-sre-action' -and
    $resolved.SRE_AGENT_PRINCIPAL_NAME -ceq 'id-sre-action') 'Explicit matching identity pair takes precedence over azd'

Reset-Discovery
Assert-Throws {
    Resolve-ZavaPostgresConfiguration `
        -ResourceGroup rg-explicit -AgentName agent-explicit `
        -PostgresHost explicit.postgres.database.azure.com `
        -SreAgentClientId client-sre-action -SreAgentPrincipalName wrong-principal `
        -AzdEnvironment @{}
} 'identity.*does not match.*attached user-assigned identity'
$resolveCall = $setupText.IndexOf('$postgresConfiguration = Resolve-ZavaPostgresConfiguration')
$configurationWrite = $setupText.IndexOf('$configuration = Get-ZavaConfiguration')
Assert ($resolveCall -ge 0 -and $resolveCall -lt $configurationWrite) 'Identity mismatch is resolved before configuration rendering or writes'

foreach ($hosts in @(@(), @('one.postgres.database.azure.com', 'two.postgres.database.azure.com'))) {
    Reset-Discovery
    $script:discovery.PostgresHosts = $hosts
    Assert-Throws {
        Resolve-ZavaPostgresConfiguration `
            -ResourceGroup rg-explicit -AgentName agent-explicit -AzdEnvironment @{}
    } 'Expected exactly one PostgreSQL Flexible Server.*found'
}

foreach ($identityIds in @(
    @(),
    @(
        '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-one',
        '/subscriptions/test/resourceGroups/rg-explicit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-two'
    )
)) {
    Reset-Discovery
    $script:discovery.Agent.properties.actionConfiguration.identity = ''
    $attached = [ordered]@{}
    foreach ($identityId in $identityIds) { $attached[$identityId] = [pscustomobject]@{} }
    $script:discovery.Agent.identity.userAssignedIdentities = [pscustomobject]$attached
    Assert-Throws {
        Resolve-ZavaPostgresConfiguration `
            -ResourceGroup rg-explicit -AgentName agent-explicit `
            -PostgresHost explicit.postgres.database.azure.com -AzdEnvironment @{}
    } 'Expected exactly one attached user-assigned identity.*found'
}

Reset-Discovery
$resolved = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup rg-explicit -AgentName agent-explicit `
    -PostgresHost explicit.postgres.database.azure.com `
    -AzdEnvironment @{ DB_NAME = 'azd_db' }
Assert ($resolved.DB_NAME -ceq 'azd_db') 'azd database name is used when no explicit name is supplied'
Reset-Discovery
$resolved = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup rg-explicit -AgentName agent-explicit `
    -AzdEnvironment @{
        DB_HOST = 'azd.postgres.database.azure.com'
        DB_NAME = 'azd_db'
        SRE_AGENT_CLIENT_ID = 'client-sre-action'
        SRE_AGENT_IDENTITY_NAME = 'id-sre-action'
    }
Assert ($resolved.DB_HOST -ceq 'azd.postgres.database.azure.com') 'Complete consistent azd PostgreSQL values are preserved'
Assert (@($script:discovery.Calls | Where-Object { $_ -match '^postgres flexible-server list ' }).Count -eq 0) 'Complete azd PostgreSQL values skip server discovery'
Reset-Discovery
$resolved = Resolve-ZavaPostgresConfiguration `
    -ResourceGroup rg-explicit -AgentName agent-explicit `
    -PostgresHost explicit.postgres.database.azure.com -AzdEnvironment @{}
Assert ($resolved.DB_NAME -ceq 'zava_store') 'Default database name is used only when explicit and azd values are absent'

$skills = @{}
foreach ($r in $configuration.Resources | Where-Object Kind -eq 'skills') { $skills[$r.Name] = $r.Body.properties }
$agents = @($configuration.Resources | Where-Object Kind -eq 'agents')
$monitor = @('system-mcp-monitor_monitor_resource_log_query', 'system-mcp-monitor_monitor_metrics_query')
foreach ($name in @('zava-application-evidence', 'zava-database-evidence')) {
    $expectedTools = if ($name -eq 'zava-database-evidence') { @('QueryZavaPostgres') + $monitor } else { $monitor }
    Compare-Equal @{ tools = $expectedTools } $skills[$name] "$name persisted tool metadata"
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
$queryResource = $configuration.Resources | Where-Object { $_.Name -eq 'QueryZavaPostgres' }
Assert ($queryResource.Path -ceq '/api/v1/extendedAgent/apply') 'Native tools use the runtime/UI apply endpoint'
Assert ($queryResource.Body.type -ceq 'PythonFunctionTool') 'Native tool write body uses the flattened runtime/UI contract'
Assert (-not $queryResource.Body.PSObject.Properties['properties']) 'Native tool write body has no v2 properties envelope'
Assert ($queryResource.Body.dependencies.Count -eq 2 -and
    $queryResource.Body.dependencies[0] -ceq 'azure-identity' -and
    $queryResource.Body.dependencies[1] -ceq 'pg8000') 'Native tool declares its pinned sandbox package names'
Assert (-not $queryResource.Body.PSObject.Properties['authEnabled']) 'Native tool omits authentication metadata that the portal serializer cannot persist'
Assert (-not $queryResource.Body.PSObject.Properties['authScopes']) 'Native tool omits authentication scopes that the portal serializer cannot persist'
Assert ($queryResource.Body.functionCode.Contains('zava-pg-offline.postgres.database.azure.com')) 'Native tool source renders the deployment database host'
Assert ($queryResource.Body.functionCode.Contains('offline-client-id')) 'Native tool source renders the deployment client ID'
Assert ($queryResource.Body.functionCode.Contains('sre-agent-zava')) 'Native tool source renders the deployment principal name'
Compare-Equal @{
    name = 'operation'
    type = 'string'
    required = $true
    mapTo = ''
    target = 'direct'
    value = $null
    validation = $null
    isDictionaryTarget = $false
} $queryResource.Body.parameters[0] 'Native tool uses the runtime ParameterView contract'
Assert ($queryResource.Body.parameters[0].description.Contains('category_query_plan')) 'Query-plan operation is exposed in the rendered tool parameter description'
Assert ($skills['zava-database-evidence'].skillContent.Contains('`category_query_plan`')) 'Database evidence skill exposes the fixed query-plan operation'
$performanceText = $skills['performance-incidents'].skillContent -replace '\s+', ' '
Assert ($performanceText.Contains('full query shape, latency, query plan, and index statistics')) 'Performance repair gate requires query-plan evidence'

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
$fallback = Get-ZavaConfiguration $root 'rg-offline' 'ExplicitAgent' $offlinePostgres
foreach ($agent in $fallback.Resources | Where-Object Kind -eq 'agents') {
    $expectedMcpTools = if ($agent.Name -eq 'database-investigator') { @('QueryZavaPostgres') + $monitor } else { $monitor }
    Compare-Equal @{ tools = @('ReadFile'); mcpTools = $expectedMcpTools } $agent.Body.properties 'Labelled explicit-agent fallback'
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
Assert ($skills['performance-incidents'].skillContent.Contains('RepairZavaPostgresIndexes')) 'Native index remediation preserved'
Assert ($skills['performance-incidents'].skillContent.Contains('ANALYZE') -and $skills['performance-incidents'].skillContent.ToLowerInvariant().Contains('reindex')) 'Parent statistics/reindex preserved'
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
$script:responseJson = '{"data":{"tools":{"data":[{"name":"QueryZavaPostgres"}]}}}'
Assert (@(Get-DataPlaneCollection '/api/v1/extendedAgent/tools?page=1&limit=200').Count -eq 1) 'Runtime tool collection decoded'
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
$script:remote = @{ tools = @(); skills = @(); agents = @(); incidentFilters = @() }
$script:writes = [Collections.Generic.List[object]]::new()
$script:acceptWithoutPersisting = $false
$script:failWrite = $false
function Get-DataPlaneCollection([string]$Path) {
    $kind = if ($Path -like '/api/v1/extendedAgent/tools*') { 'tools' } else { ($Path -split '/')[-1] }
    return @($script:remote[$kind])
}
function Invoke-DataPlaneWrite($Path, $Body, $Label, $MaxAttempts, $Method = 'Put', $ContentType = 'application/json') {
    $script:writes.Add(@{ path = $Path; body = Copy-Json $Body; method = $Method; contentType = $ContentType })
    if ($script:failWrite) { return $false }
    if (-not $script:acceptWithoutPersisting) {
        $kind = if ($Path -ceq '/api/v1/extendedAgent/apply') { 'tools' } else { ($Path -split '/')[-2] }
        $replacement = if ($kind -eq 'tools') {
            $applied = $Body.spec.tools[0]
            Copy-Json ([ordered]@{
                name = $applied.name
                type = $applied.type
                description = $applied.description
                functionCode = $applied.function_code
                timeoutSeconds = $applied.timeout_seconds
                dependencies = $applied.dependencies
                parameters = @($applied.parameters | ForEach-Object {
                    [ordered]@{
                        name = $_.name
                        type = $_.type
                        description = $_.description
                        mapTo = ''
                        required = $_.required
                        target = $_.target
                        value = $null
                        validation = $null
                        isDictionaryTarget = $false
                    }
                })
            })
        } else { Copy-Json $Body }
        $saved = @($script:remote[$kind] | Where-Object name -ceq $replacement.name)
        if ($Method -eq 'Patch') {
            Assert ($saved.Count -eq 1) 'PATCH requires an existing resource'
            foreach ($property in $saved[0].properties.PSObject.Properties) {
                if (-not $replacement.properties.PSObject.Properties[$property.Name]) {
                    $replacement.properties | Add-Member NoteProperty $property.Name $property.Value
                }
            }
        }
        $script:remote[$kind] = @($script:remote[$kind] | Where-Object name -cne $replacement.name) + @($replacement)
    }
    return $true
}
$unmanaged = @{ name = 'operator-agent'; type = 'ExtendedAgent'; tags = @('keep'); properties = @{ instructions = 'untouched' } }
$script:remote.agents = @(Copy-Json $unmanaged)
$plan = New-ZavaSyncPlan $configuration $script:remote ''
Assert-ZavaUpdateApproved $plan
foreach ($kind in @('tools', 'skills', 'agents', 'incidentFilters')) { Sync-ZavaResources $plan $kind }
Assert ($script:writes.Count -eq 17) "First apply writes exactly managed objects (actual $($script:writes.Count))"
Assert (@($script:writes | Where-Object method -ne 'Put').Count -eq 0) 'New resources use PUT'
$toolWrites = @($script:writes | Where-Object path -ceq '/api/v1/extendedAgent/apply')
Assert ($toolWrites.Count -eq 2) 'Native tools use the v1 apply endpoint'
Assert (@($toolWrites | Where-Object contentType -cne 'application/x-yaml').Count -eq 0) 'Native tools use the YAML apply content type'
Assert (@($toolWrites | Where-Object {
    $_.body.api_version -cne 'azuresre.ai/v1' -or
    $_.body.kind -cne 'ToolList' -or
    $_.body.spec.tools.Count -ne 1
}).Count -eq 0) 'Each native tool uses the versioned ToolList apply contract'
foreach ($toolWrite in $toolWrites) {
    $appliedTool = $toolWrite.body.spec.tools[0]
    Assert ($appliedTool.function_code -is [string] -and $appliedTool.function_code.Length -gt 0) 'ToolList uses function_code'
    Assert ($appliedTool.timeout_seconds -eq 120) 'ToolList uses timeout_seconds'
    Assert ($appliedTool.dependencies.Count -eq 2 -and
        $appliedTool.dependencies[0] -ceq 'azure-identity' -and
        $appliedTool.dependencies[1] -ceq 'pg8000') 'ToolList declares the Python package dependencies'
    $appliedParameter = $appliedTool.parameters[0]
    Assert ($appliedParameter.name -ceq 'operation' -and
        $appliedParameter.type -ceq 'string' -and
        $appliedParameter.required -eq $true -and
        $appliedParameter.description -is [string] -and
        $appliedParameter.target -ceq 'direct') 'ToolList uses the portal Python parameter schema'
    foreach ($runtimeField in @('mapTo', 'map_to', 'value', 'validation', 'isDictionaryTarget')) {
        Assert (-not $appliedParameter.PSObject.Properties[$runtimeField]) "ToolList omits runtime-only parameter field $runtimeField"
    }
    Assert (-not $appliedTool.PSObject.Properties['functionCode']) 'ToolList omits camelCase functionCode'
    Assert (-not $appliedTool.PSObject.Properties['timeoutSeconds']) 'ToolList omits camelCase timeoutSeconds'
    Assert (-not $appliedTool.PSObject.Properties['auth_enabled']) 'ToolList omits unsupported auth_enabled metadata'
    Assert (-not $appliedTool.PSObject.Properties['auth_scopes']) 'ToolList omits unsupported auth_scopes metadata'
    Assert (-not $appliedTool.PSObject.Properties['authEnabled']) 'ToolList omits camelCase authEnabled'
    Assert (-not $appliedTool.PSObject.Properties['authScopes']) 'ToolList omits camelCase authScopes'
}
Compare-Equal $unmanaged $script:remote.agents[0] 'Unmanaged agent untouched'
$plan = New-ZavaSyncPlan $configuration $script:remote $configuration.CustomInstructions
Assert (@($plan.Items | Where-Object Action -ne 'skip').Count -eq 0) 'Second apply is a no-op'
Assert (-not $plan.InstructionsChanged) 'Instructions no-op'
foreach ($kind in @('tools', 'skills', 'agents', 'incidentFilters')) { Sync-ZavaResources $plan $kind }
Assert ($script:writes.Count -eq 17) 'No extra writes on reapply'
$tool = $script:remote.tools | Where-Object name -eq 'QueryZavaPostgres'
$tool.type = 'OtherTool'
$plan = New-ZavaSyncPlan $configuration $script:remote $configuration.CustomInstructions
$toolItem = $plan.Items | Where-Object { $_.Resource.Name -eq 'QueryZavaPostgres' }
Assert ($toolItem.Action -eq 'update' -and ($toolItem.Differences -contains 'tools/QueryZavaPostgres.type differs')) 'Tool type drift is detected'
$tool.type = 'PythonFunctionTool'
$tool.description = 'operator-edited description'
$plan = New-ZavaSyncPlan $configuration $script:remote $configuration.CustomInstructions
$toolItem = $plan.Items | Where-Object { $_.Resource.Name -eq 'QueryZavaPostgres' }
Assert ($toolItem.Action -eq 'update' -and ($toolItem.Differences -contains 'tools/QueryZavaPostgres.description differs')) 'Tool description drift is detected'
$tool.description = $queryResource.Body.description

$savedApp = $script:remote.agents | Where-Object name -eq 'app-investigator'
$savedApp.properties.instructions = 'operator-edited instructions'
$savedApp.tags = @('operator-tag')
$savedApp.properties | Add-Member NoteProperty temperature 0.2
$savedApp.properties | Add-Member NoteProperty llmModelName 'operator-selected-model'
$savedApp.properties | Add-Member NoteProperty enableSkills $true
$plan = New-ZavaSyncPlan $configuration $script:remote 'operator global instructions'
Assert-Throws { Assert-ZavaUpdateApproved $plan } 'Nothing has been written'
Assert ($script:writes.Count -eq 17) 'Preflight drift refusal has no writes'
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
    $coreConfig = Get-ZavaConfiguration $fixture 'rg-test' 'SkillOwned' $offlinePostgres
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
        Assert-Throws { Get-ZavaConfiguration $fixture 'rg-test' 'SkillOwned' $offlinePostgres } $change.error
    }
    $original | Set-Content -LiteralPath $appPath
    '@@SHARED@@' | Set-Content (Join-Path $fixture 'skills\zava-application-evidence.md')
    Assert-Throws { Get-ZavaConfiguration $fixture 'rg-test' 'SkillOwned' $offlinePostgres } 'Shared context is not permitted'
    '@@UNRESOLVED@@' | Set-Content (Join-Path $fixture 'skills\zava-application-evidence.md')
    Assert-Throws { Get-ZavaConfiguration $fixture 'rg-test' 'SkillOwned' $offlinePostgres } 'unresolved configuration placeholder'
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
