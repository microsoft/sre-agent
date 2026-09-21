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
$renderer = Join-Path $scriptDir 'internal/render-pr-validation-template.py'
$applyExtras = Join-Path $repoRoot 'sreagent-templates/bicep/Apply-Extras.ps1'

foreach ($path in @($Template, $renderer, $applyExtras)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file not found: $path" }
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Required command not found: az' }

$python = Get-Command py -ErrorAction SilentlyContinue
if ($python) {
    $pythonArgs = @('-3')
} else {
    $python = Get-Command python -ErrorAction Stop
    $pythonArgs = @()
}
& $python.Source @pythonArgs -c 'import yaml' 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Python 3 with PyYAML is required.' }

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "onboarding-pr-validation-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $extrasFile = Join-Path $tempDir 'pr-validation.extras.json'
    $agentExtrasFile = Join-Path $tempDir 'pr-validation-agent.extras.json'
    $triggerExtrasFile = Join-Path $tempDir 'pr-validation-trigger.extras.json'
    & $python.Source @pythonArgs $renderer --template $Template --output $extrasFile
    if ($LASTEXITCODE -ne 0) { throw 'PR-validation template rendering failed.' }

    $resources = @(& az resource list --subscription $Subscription --resource-type Microsoft.App/agents `
        --query "[?name=='$AgentName'].{id:id,resourceGroup:resourceGroup}" --output json | ConvertFrom-Json)
    if ($resources.Count -ne 1) { throw "Expected exactly one agent named $AgentName" }
    $resourceGroup = $resources[0].resourceGroup
    $agentResource = (& az rest --method GET --url "https://management.azure.com$($resources[0].id)?api-version=2025-05-01-preview" --output json) | ConvertFrom-Json
    $endpoint = $agentResource.properties.agentEndpoint.TrimEnd('/')
    if (-not $endpoint.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { throw 'Agent endpoint is unavailable.' }

    $extras = Get-Content -LiteralPath $extrasFile -Raw | ConvertFrom-Json
    $connectors = (& az rest --method GET --url "https://management.azure.com$($resources[0].id)/DataConnectors?api-version=2025-05-01-preview" --output json) | ConvertFrom-Json
    $telemetryTools = @($connectors.value | Where-Object {
        $_.properties.provisioningState -in @('Succeeded', 'Running')
    } | ForEach-Object {
        switch ($_.properties.dataConnectorType) {
            'AppInsights' { 'QueryAppInsightsUsingAppId' }
            'LogAnalytics' { 'QueryLogAnalyticsByWorkspaceId' }
        }
    } | Sort-Object -Unique)
    $extras.subagents[0].spec.tools = @($extras.subagents[0].spec.tools + $telemetryTools | Sort-Object -Unique)
    $extras | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $extrasFile -Encoding utf8

    @{ skills = $extras.skills; subagents = $extras.subagents } |
        ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $agentExtrasFile -Encoding utf8
    Write-Host 'Installing Scenario 3 skill and PR validator...'
    & $applyExtras -Subscription $Subscription -ResourceGroup $resourceGroup -AgentName $AgentName -ExtrasFile $agentExtrasFile

    @{ httpTriggers = $extras.httpTriggers; enableWebhookBridge = $extras.enableWebhookBridge } |
        ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $triggerExtrasFile -Encoding utf8
    Write-Host 'Installing Scenario 3 HTTP trigger and webhook bridge...'
    & $applyExtras -Subscription $Subscription -ResourceGroup $resourceGroup -AgentName $AgentName -ExtrasFile $triggerExtrasFile

    $token = (& az account get-access-token --resource https://azuresre.dev --query accessToken --output tsv).Trim()
    $headers = @{ Authorization = "Bearer $token" }
    $expectedAgent = $extras.installerRequirements.agentName
    $installedAgent = Invoke-RestMethod -Uri "$endpoint/api/v2/extendedAgent/agents/$expectedAgent" -Headers $headers
    foreach ($toolName in $extras.subagents[0].spec.tools) {
        if ($toolName -notin $installedAgent.properties.tools) { throw "PR validator is missing tool: $toolName" }
    }
    if ($extras.installerRequirements.skillName -notin $installedAgent.properties.allowedSkills) {
        throw "PR validator is missing skill: $($extras.installerRequirements.skillName)"
    }
    $installedSkill = Invoke-RestMethod -Uri "$endpoint/api/v2/extendedAgent/skills/$($extras.installerRequirements.skillName)" -Headers $headers
    if ($installedSkill.name -ne $extras.installerRequirements.skillName) { throw 'PR-validation skill verification failed.' }

    $triggerResponse = Invoke-RestMethod -Uri "$endpoint/api/v1/httpTriggers" -Headers $headers
    $triggers = if ($triggerResponse.value) { @($triggerResponse.value) } else { @($triggerResponse) }
    $trigger = @($triggers | Where-Object { $_.name -eq $extras.installerRequirements.triggerName })
    if ($trigger.Count -ne 1 -or $trigger[0].agent -ne $expectedAgent -or $trigger[0].agentMode -ne 'Review') {
        throw "PR-validation HTTP trigger verification failed: $($extras.installerRequirements.triggerName)"
    }

    $logicAppName = "$AgentName-webhook-bridge"
    $logicApps = @(& az resource list --subscription $Subscription --resource-group $resourceGroup `
        --resource-type Microsoft.Logic/workflows --query "[?name=='$logicAppName'].name" --output tsv)
    if ($logicApps.Count -ne 1) { throw "Webhook bridge verification failed: $logicAppName" }
    $callbackUrl = (& az rest --method POST --url `
        "/subscriptions/$Subscription/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/$logicAppName/triggers/incoming_webhook/listCallbackUrl?api-version=2019-05-01" `
        --query value --output tsv).Trim()
    if (-not $callbackUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { throw 'Webhook callback URL verification failed.' }

    Write-Host "Scenario 3 installed: $($trigger[0].name) -> $expectedAgent (Review)."
    Write-Host 'Store this callback URL as the GitHub Actions secret SRE_AGENT_WEBHOOK_URL:'
    Write-Host "  $callbackUrl"
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}