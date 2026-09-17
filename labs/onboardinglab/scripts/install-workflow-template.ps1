#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string] $Subscription,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*$')][string] $AgentName,
    [Parameter(Mandatory)][string] $Template,
    [switch] $EnableSourceCode,
    [switch] $EnableGitHubIssues,
    [switch] $EnableEmail,
    [string] $GitHubRepository,
    [string] $EmailRecipients
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
    $PSNativeCommandUseErrorActionPreference = $false
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

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "onboarding-workflow-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $extrasFile = Join-Path $tempDir 'workflow.extras.json'
    $agentExtrasFile = Join-Path $tempDir 'workflow-agent.extras.json'
    $rendererArgs = @('--template', $Template, '--output', $extrasFile)
    if ($EnableSourceCode) { $rendererArgs += '--enable-source-code' }
    if ($EnableGitHubIssues) { $rendererArgs += '--enable-github-issues' }
    if ($EnableEmail) { $rendererArgs += '--enable-email' }
    if ($GitHubRepository) { $rendererArgs += @('--github-repository', $GitHubRepository) }
    if ($EmailRecipients) { $rendererArgs += @('--email-recipients', $EmailRecipients) }
    & $python.Command @($python.Arguments) $renderer @rendererArgs

    $agents = @(& az resource list --subscription $Subscription --resource-type Microsoft.App/agents `
        --query "[?name=='$AgentName'].{id:id,resourceGroup:resourceGroup}" --output json | ConvertFrom-Json)
    if ($agents.Count -ne 1) { throw "Expected exactly one agent named $AgentName in subscription $Subscription" }
    $resourceGroup = $agents[0].resourceGroup
    $agentId = $agents[0].id
    Write-Host "  ok existing agent: $AgentName ($resourceGroup)"
    $agent = (& az rest --method GET --url "https://management.azure.com$agentId`?api-version=2025-05-01-preview" --output json) | ConvertFrom-Json
    $extras = Get-Content -LiteralPath $extrasFile -Raw | ConvertFrom-Json
    if (-not $agent.properties.agentEndpoint -or -not $agent.properties.agentEndpoint.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Agent endpoint is unavailable'
    }
    $connectors = (& az rest --method GET --url "https://management.azure.com$agentId/DataConnectors?api-version=2025-05-01-preview" --output json) | ConvertFrom-Json
    $token = (& az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv).Trim()
    if (-not $token) { throw 'SRE Agent data-plane token is unavailable' }
    $headers = @{ Authorization = "Bearer $token" }
    $endpoint = $agent.properties.agentEndpoint.TrimEnd('/')
    $state = @{ agent = $agent; connectors = $connectors }
    if ($EnableSourceCode -or $EnableGitHubIssues) {
        $state.repos = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/repos" -Headers $headers -TimeoutSec 30
        $state.githubDomains = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/github/domains" -Headers $headers -TimeoutSec 30
    }
    if ($EnableEmail) {
        $state.managedConnectors = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/connectorV2/mcpservers" -Headers $headers -TimeoutSec 30
        $state.emailConnection = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/connectorV2/connections/office365" -Headers $headers -TimeoutSec 30
    }
    $stateFile = Join-Path $tempDir 'prerequisites.json'
    $state | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $stateFile -Encoding utf8
    & $python.Command @($python.Arguments) $renderer @rendererArgs --prerequisite-state $stateFile
    $extras = Get-Content -LiteralPath $extrasFile -Raw | ConvertFrom-Json
    Write-Host 'Workflow prerequisites validated.'

    @{ skills = $extras.skills; subagents = $extras.subagents } |
        ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $agentExtrasFile -Encoding utf8
    Write-Host 'Installing workflow skills and subagent...'
    & $applyExtras -Subscription $Subscription -ResourceGroup $resourceGroup -AgentName $AgentName -ExtrasFile $agentExtrasFile

    $token = (& az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv).Trim()
    $headers = @{ Authorization = "Bearer $token" }
    $endpoint = $agent.properties.agentEndpoint.TrimEnd('/')
    $customAgentName = $extras.installerRequirements.customAgentName
    $filterName = $extras.installerRequirements.workflowName
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

    $installedAgent = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/agents/$customAgentName" -Headers $headers
    if ($installedAgent.name -ne $customAgentName) { throw "Custom agent verification failed: $customAgentName" }
    if (Compare-Object @($extras.subagents[0].spec.tools) @($installedAgent.properties.tools)) {
        throw "Custom agent tool set differs from selected capabilities: $customAgentName"
    }
    foreach ($toolName in $extras.installerRequirements.deniedTools) {
        if ($toolName -in $installedAgent.properties.tools) { throw "Custom agent contains denied tool: $toolName" }
    }
    foreach ($skillName in $extras.installerRequirements.skillNames) {
        $installedSkill = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/skills/$skillName" -Headers $headers
        if ($installedSkill.name -ne $skillName) { throw "Skill verification failed: $skillName" }
    }
    if (Compare-Object @($extras.installerRequirements.skillNames) @($installedAgent.properties.allowedSkills)) {
        throw "Custom agent skill set differs from selected capabilities: $customAgentName"
    }
    $filter = Invoke-RestMethod -Method Get -Uri "$endpoint/api/v2/extendedAgent/incidentFilters/$filterName" -Headers $headers
    if ($filter.properties.handlingAgent -ne $customAgentName -or $filter.properties.agentMode -ne $responsePlan.spec.agentMode -or
        (Compare-Object @($filter.properties.priorities) @($responsePlan.spec.priorities)) -or
        $filter.properties.titleContains -ne $responsePlan.spec.titleContains -or
        $filter.properties.isEnabled -ne $responsePlan.spec.isEnabled -or
        $filter.properties.mergeEnabled -ne $responsePlan.spec.mergeEnabled -or
        $filter.properties.mergeWindowHours -ne $responsePlan.spec.mergeWindowHours) {
        throw "Response plan verification failed: $filterName"
    }
    Write-Host "Workflow $filterName installed with response plan $filterName connected to subagent $customAgentName."
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}