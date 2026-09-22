#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string] $Subscription,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*$')][string] $AgentName,
    [Parameter(Mandatory)][string] $Template
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$scriptDir = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path
$renderer = Join-Path $scriptDir 'internal/render-workflow-template.py'
$applyExtras = Join-Path $repoRoot 'sreagent-templates/bicep/Apply-Extras.ps1'

if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) { throw "Template not found: $Template" }
if (-not (Test-Path -LiteralPath $renderer -PathType Leaf)) { throw "Renderer not found: $renderer" }
if (-not (Test-Path -LiteralPath $applyExtras -PathType Leaf)) { throw "Shared extras installer not found: $applyExtras" }
foreach ($command in @('az', 'jq')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required command not found: $command" }
}

function Get-WorkflowPython {
    foreach ($candidate in @(
        @{ Command = 'py'; Arguments = @('-3') },
        @{ Command = 'python'; Arguments = @() },
        @{ Command = 'python3'; Arguments = @() }
    )) {
        $resolved = Get-Command $candidate.Command -ErrorAction SilentlyContinue
        if (-not $resolved) { continue }
        & $resolved.Source @($candidate.Arguments) -c 'import yaml' 2>$null
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ Command = $resolved.Source; Arguments = @($candidate.Arguments) }
        }
    }
    throw 'A working Python 3 interpreter with PyYAML is required. Run . .\scripts\prereqs.ps1, then retry.'
}

$python = Get-WorkflowPython
$triggerType = (& $python.Command @($python.Arguments) -c "import sys, yaml; print((yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}).get('trigger', {}).get('type', ''))" $Template).Trim()
if ($triggerType -eq 'http-trigger') {
    & (Join-Path $scriptDir 'install-pr-validation.ps1') `
        -Subscription $Subscription -AgentName $AgentName -Template $Template
    return
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "onboarding-workflow-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $extrasFile = Join-Path $tempDir 'workflow.extras.json'
    $agentExtrasFile = Join-Path $tempDir 'workflow-agent.extras.json'
    $scheduledTaskExtrasFile = Join-Path $tempDir 'workflow-scheduled-task.extras.json'
    & $python.Command @($python.Arguments) $renderer --template $Template --output $extrasFile

    $agents = @(& az resource list --subscription $Subscription --resource-type Microsoft.App/agents `
        --query "[?name=='$AgentName'].{id:id,resourceGroup:resourceGroup}" --output json | ConvertFrom-Json)
    if ($agents.Count -ne 1) { throw "Expected exactly one agent named $AgentName in subscription $Subscription" }
    $resourceGroup = $agents[0].resourceGroup
    $agentId = $agents[0].id
    Write-Host "  ok existing agent: $AgentName ($resourceGroup)"
    $agent = (& az rest --method GET --url "https://management.azure.com$agentId`?api-version=2025-05-01-preview" --output json) | ConvertFrom-Json
    $extras = Get-Content -LiteralPath $extrasFile -Raw | ConvertFrom-Json
    $requiredIncidentPlatform = $extras.installerRequirements.incidentPlatform
    if ($requiredIncidentPlatform -and
        $agent.properties.incidentManagementConfiguration.type -ne $requiredIncidentPlatform) {
        throw "Agent incident platform is $($agent.properties.incidentManagementConfiguration.type); expected $requiredIncidentPlatform"
    }
    if (-not $agent.properties.agentEndpoint.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Agent endpoint is unavailable'
    }
    if ($requiredIncidentPlatform) {
        Write-Host "  ok incident platform: $($agent.properties.incidentManagementConfiguration.type)"
    }

    $connectors = (& az rest --method GET --url "https://management.azure.com$agentId/DataConnectors?api-version=2025-05-01-preview" --output json) | ConvertFrom-Json
    $healthy = @($connectors.value | Where-Object {
        $_.properties.dataConnectorType -in @('AppInsights', 'LogAnalytics') -and
        $_.properties.provisioningState -in @('Succeeded', 'Running')
    }).Count
    if ($healthy -lt $extras.installerRequirements.minimumTelemetryConnectors) {
        throw "Found $healthy healthy telemetry connectors; expected at least $($extras.installerRequirements.minimumTelemetryConnectors)"
    }
    $telemetryTools = @($connectors.value | Where-Object {
        $_.properties.provisioningState -in @('Succeeded', 'Running')
    } | ForEach-Object {
        switch ($_.properties.dataConnectorType) {
            'AppInsights' { 'QueryAppInsightsUsingAppId' }
            'LogAnalytics' { 'QueryLogAnalyticsByWorkspaceId' }
        }
    } | Sort-Object -Unique)
    Write-Host "  ok healthy telemetry connectors: $healthy"
    Write-Host "  ok telemetry query tools: $($telemetryTools -join ', ')"
    Write-Host 'Workflow prerequisites validated.'
    foreach ($subagent in $extras.subagents) {
        $subagent.spec.tools = @($subagent.spec.tools + $telemetryTools | Sort-Object -Unique)
    }

    @{ skills = $extras.skills; subagents = $extras.subagents } |
        ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $agentExtrasFile -Encoding utf8
    Write-Host 'Installing workflow skills and subagents...'
    & $applyExtras -Subscription $Subscription -ResourceGroup $resourceGroup -AgentName $AgentName -ExtrasFile $agentExtrasFile

    if (@($extras.scheduledTasks).Count -gt 0) {
        @{ scheduledTasks = $extras.scheduledTasks } |
            ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $scheduledTaskExtrasFile -Encoding utf8
        Write-Host 'Installing scheduled task after its handling subagent...'
        & $applyExtras -Subscription $Subscription -ResourceGroup $resourceGroup -AgentName $AgentName -ExtrasFile $scheduledTaskExtrasFile
    }

    $token = (& az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv).Trim()
    $headers = @{ Authorization = "Bearer $token" }
    $endpoint = $agent.properties.agentEndpoint.TrimEnd('/')
    $customAgentName = $extras.installerRequirements.customAgentName
    $filterName = $extras.installerRequirements.workflowName
    if (@($extras.incidentFilters).Count -gt 0) {
        $responsePlan = $extras.incidentFilters[0]
        $responsePlanBody = @{
            name = $responsePlan.metadata.name
            type = 'IncidentFilter'
            tags = @()
            properties = $responsePlan.spec
        } | ConvertTo-Json -Depth 20 -Compress
        Write-Host 'Creating response plan and connecting it to the subagent...'
        $responsePlanResult = Invoke-WebRequest -Method Put `
            -Uri "$endpoint/api/v2/extendedAgent/incidentFilters/$filterName" `
            -Headers $headers -ContentType 'application/json' -Body $responsePlanBody `
            -SkipHttpErrorCheck -TimeoutSec 30
        if ($responsePlanResult.StatusCode -lt 200 -or $responsePlanResult.StatusCode -ge 300) {
            throw "Response plan $filterName was rejected (HTTP $($responsePlanResult.StatusCode)): $($responsePlanResult.Content)"
        }
        Write-Host "  ok response plan: $filterName -> $customAgentName"
    }

    foreach ($expectedAgent in $extras.subagents) {
        $expectedAgentName = $expectedAgent.metadata.name
        $installedAgent = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/agents/$expectedAgentName" -Headers $headers
        if ($installedAgent.name -ne $expectedAgentName) { throw "Custom agent verification failed: $expectedAgentName" }
        foreach ($toolName in $expectedAgent.spec.tools) {
            if ($toolName -notin $installedAgent.properties.tools) { throw "Custom agent $expectedAgentName is missing tool: $toolName" }
        }
        foreach ($skillName in $expectedAgent.spec.allowedSkills) {
            if ($skillName -notin $installedAgent.properties.allowedSkills) {
                throw "Custom agent $expectedAgentName is missing skill: $skillName"
            }
        }
    }
    $installedCustomAgent = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/agents/$customAgentName" -Headers $headers
    foreach ($toolName in $extras.installerRequirements.deniedTools) {
        if ($toolName -in $installedCustomAgent.properties.tools) { throw "Custom agent contains denied tool: $toolName" }
    }
    foreach ($skillName in $extras.installerRequirements.skillNames) {
        $installedSkill = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/skills/$skillName" -Headers $headers
        if ($installedSkill.name -ne $skillName) { throw "Skill verification failed: $skillName" }
    }
    if (@($extras.incidentFilters).Count -gt 0) {
        $expectedFilter = $extras.incidentFilters[0]
        $filter = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/incidentFilters/$filterName" -Headers $headers
        if ($filter.properties.handlingAgent -ne $customAgentName -or
            $filter.properties.agentMode -ne $expectedFilter.spec.agentMode -or
            (Compare-Object @($filter.properties.priorities) @($expectedFilter.spec.priorities))) {
            throw "Response plan verification failed: $filterName"
        }
    }
    if (@($extras.scheduledTasks).Count -gt 0) {
        $scheduledTaskName = $extras.installerRequirements.scheduledTaskName
        $scheduledTaskSchedule = $extras.installerRequirements.scheduledTaskSchedule
        $scheduledTaskAgentName = $extras.installerRequirements.scheduledTaskAgentName
        $scheduledTaskResponse = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/scheduledtasks" -Headers $headers
        $scheduledTasks = if ($scheduledTaskResponse.value) { @($scheduledTaskResponse.value) } else { @($scheduledTaskResponse) }
        $scheduledTask = @($scheduledTasks | Where-Object { $_.name -eq $scheduledTaskName })
        $scheduledTaskIsActive = $scheduledTask.Count -eq 1 -and
            ($scheduledTask[0].properties.status -eq 'Active' -or $scheduledTask[0].properties.isEnabled -eq $true)
        if ($scheduledTask.Count -ne 1 -or $scheduledTask[0].properties.cronExpression -ne $scheduledTaskSchedule -or
            $scheduledTask[0].properties.agent -ne $scheduledTaskAgentName -or
            $scheduledTask[0].properties.agentMode -ne 'Review' -or -not $scheduledTaskIsActive) {
            throw "Scheduled task verification failed: $scheduledTaskName"
        }
    }
    Write-Host "Scenario $filterName installed and verified."
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}