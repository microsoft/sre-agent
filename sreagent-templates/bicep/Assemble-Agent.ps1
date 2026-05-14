<#
.SYNOPSIS
    Reconstruct deploy-ready files from an exported directory layout.

.DESCRIPTION
    Reads the structured directory produced by export-agent.sh and assembles:
      <dir>.parameters.json  — Bicep-deployable (for deploy.sh)
      <dir>.extras.json      — Data-plane config (for apply-extras.sh)

    The directory must contain agent.json. All other files are optional.
    File references in config/ JSONs (paths to .md files) are resolved inline.

.EXAMPLE
    ./Assemble-Agent.ps1 -ConfigDir ./my-agent-export
    ./Assemble-Agent.ps1 -ConfigDir ./my-agent-export -Secrets ./connectors.secrets.env
    ./Assemble-Agent.ps1 -ConfigDir ./my-agent-export -Output /tmp/my-agent

.NOTES
    Prerequisites: jq, python3, PyYAML (pip install pyyaml)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias("d")]
    [string]$ConfigDir,

    [Alias("o")]
    [string]$Output,

    [Alias("s")]
    [string]$Secrets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve paths ──

$ConfigDir = (Resolve-Path $ConfigDir).Path.TrimEnd([IO.Path]::DirectorySeparatorChar)

if (-not (Test-Path $ConfigDir -PathType Container)) {
    Write-Error "Directory not found: $ConfigDir"
}
if (-not (Test-Path (Join-Path $ConfigDir 'agent.json'))) {
    Write-Error "agent.json not found in $ConfigDir"
}
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Error "jq is required but not found in PATH"
}

if (-not $Output) { $Output = $ConfigDir }
if (-not $Secrets) { $Secrets = Join-Path $ConfigDir 'connectors.secrets.env' }

$ParamsFile = "${Output}.parameters.json"
$ExtrasFile = "${Output}.extras.json"

function Write-Log  { param([string]$Msg) Write-Host "  $Msg" }
function Write-Info { param([string]$Msg) Write-Host "── $Msg ──" }

# ── Load secrets into environment variables (for connector token substitution) ──

if (Test-Path $Secrets -PathType Leaf) {
    Write-Info "Loading secrets from $Secrets"
    foreach ($line in (Get-Content $Secrets)) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $eqIdx = $line.IndexOf('=')
        if ($eqIdx -gt 0) {
            $key   = $line.Substring(0, $eqIdx)
            $value = $line.Substring($eqIdx + 1)
            [Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }
}

# ── Helper: resolve file references in JSON ──
# Config JSONs use relative paths like "skills/my-skill.md" for content fields.
# This reads the file and inlines its content.

function Resolve-FileRefs {
    param([string]$Json, [string]$BaseDir)

    $pyScript = @'
import json, sys, os

base = sys.argv[1]
data = json.load(sys.stdin)

def resolve(obj):
    if isinstance(obj, str):
        for prefix in ['skills/', 'subagents/', 'common-prompts/']:
            if obj.startswith(prefix) and obj.endswith(('.md', '.txt')):
                for config_base in ['config']:
                    path = os.path.join(base, config_base, obj)
                    if os.path.isfile(path):
                        with open(path) as f:
                            return f.read()
        if obj.startswith('_file:'):
            path = os.path.join(base, obj[6:])
            if os.path.isfile(path):
                with open(path) as f:
                    return f.read()
        return obj
    elif isinstance(obj, dict):
        return {k: resolve(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [resolve(v) for v in obj]
    return obj

print(json.dumps(resolve(data)))
'@

    try {
        $result = $Json | python3 -c $pyScript $BaseDir 2>$null
        if ($LASTEXITCODE -eq 0 -and $result) { return $result }
    } catch {}
    return $Json
}

# ── Helper: collect all YAML (or JSON) files from a config subdirectory into a JSON array ──
# Reads from config/ and automations/

function Collect-Config {
    param([string]$Subdir)

    $result = '[]'
    foreach ($base in @((Join-Path $ConfigDir 'config'), (Join-Path $ConfigDir 'automations'))) {
        $full = Join-Path $base $Subdir
        if (-not (Test-Path $full -PathType Container)) { continue }

        $items = '[]'

        # Read YAML files
        # NOTE: Get-ChildItem ignores -Include unless the path has a wildcard or -Recurse
        # is used, so we glob explicitly per extension via -Filter.
        $yamlFiles = @()
        $yamlFiles += Get-ChildItem $full -File -Filter '*.yaml' -ErrorAction SilentlyContinue
        $yamlFiles += Get-ChildItem $full -File -Filter '*.yml'  -ErrorAction SilentlyContinue
        foreach ($f in $yamlFiles) {
            $pyYaml = @'
import sys, yaml, json
with open(sys.argv[1]) as fh:
    data = yaml.safe_load(fh)
print(json.dumps(data))
'@
            try {
                $item = python3 -c $pyYaml $f.FullName 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $item) { continue }
                $items = $items | jq -c --argjson i $item '. + [$i]'
            } catch { continue }
        }

        # Read JSON files (backward compat)
        foreach ($f in (Get-ChildItem $full -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try {
                $item = Get-Content $f.FullName -Raw
                $items = ($items, $item) | jq -sc 'add // []' 2>$null
                if ($LASTEXITCODE -ne 0) { continue }
            } catch { continue }
        }

        $result = ($result, $items) | jq -sc 'add // []'
    }
    return $result
}

# ── Helper: substitute env vars in connector JSON ──

function Resolve-EnvVars {
    param([string]$Json)

    $pyScript = @'
import json, sys, os, re

data = json.load(sys.stdin)

def sub(obj):
    if isinstance(obj, str):
        return re.sub(r'\$\{(\w+)\}', lambda m: os.environ.get(m.group(1), m.group(0)), obj)
    elif isinstance(obj, dict):
        return {k: sub(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [sub(v) for v in obj]
    return obj

print(json.dumps(sub(data)))
'@

    try {
        $result = $Json | python3 -c $pyScript 2>$null
        if ($LASTEXITCODE -eq 0 -and $result) { return $result }
    } catch {}
    return $Json
}

# ═══════ Read agent.json ═══════

Write-Info 'Reading agent.json'
$agentJson = Get-Content (Join-Path $ConfigDir 'agent.json') -Raw

$agentName      = $agentJson | jq -r '.identity.agentName'
$agentRg        = $agentJson | jq -r '.identity.resourceGroup'
$agentSub       = $agentJson | jq -r '.identity.subscription // ""'
$agentLoc       = $agentJson | jq -r '.identity.location'
$targetRgs      = $agentJson | jq -c 'if .identity.targetResourceGroups | type == "array" then .identity.targetResourceGroups elif .identity.targetResourceGroups | type == "string" and length > 0 then [.identity.targetResourceGroups | split(",")[] | gsub("^\\s+|\\s+$"; "")] else [] end'
$access         = $agentJson | jq -r '.access.accessLevel'
$action         = $agentJson | jq -r '.access.actionMode'
$toggles        = $agentJson | jq -c '.toggles // {}'
$upgradeChannel = $agentJson | jq -r '.upgradeChannel // "Preview"'
$modelProvider  = $agentJson | jq -r '.defaultModelProvider // "Anthropic"'
$monthlyLimit   = $agentJson | jq -r '.monthlyAgentUnitLimit // 10000'
$tags           = $agentJson | jq -c '.tags // {}'
$existingUami   = $agentJson | jq -r '.existingUamiId // ""'
$existingAi     = $agentJson | jq -r '.existingAgentAppInsightsId // ""'

Write-Log "Agent: $agentName ($agentLoc, $agentRg)"

# ═══════ Read connectors.json ═══════

Write-Info 'Reading connectors.json'
$connectors       = '[]'
$connectorToggles = '{}'
$connFile = Join-Path $ConfigDir 'connectors.json'

if (Test-Path $connFile -PathType Leaf) {
    $rawConn = Resolve-EnvVars (Get-Content $connFile -Raw)
    $isArray = $rawConn | jq -e 'type == "array"' 2>$null
    if ($LASTEXITCODE -eq 0) {
        $connectors = $rawConn
    } else {
        $connectorToggles = $rawConn | jq -c '.toggles // {}'
        $connectors       = $rawConn | jq -c '.connectors // []'
    }
    $connCount = $connectors | jq 'length'
    Write-Log "$connCount connector(s) from connectors.json"

    # Auto-enrich AppInsights connectors: resolve missing appId / armResourceId / resource.name
    # from the connector's dataSource (full ARM resource ID).
    $connArr = @($connectors | ConvertFrom-Json -ErrorAction SilentlyContinue)
    $changed = $false
    foreach ($c in $connArr) {
        if ($null -eq $c -or $null -eq $c.properties) { continue }
        if ($c.properties.dataConnectorType -ne 'AppInsights') { continue }
        $aiId = "$($c.properties.dataSource)"
        if ([string]::IsNullOrWhiteSpace($aiId)) { continue }

        if (-not $c.properties.PSObject.Properties['extendedProperties'] -or $null -eq $c.properties.extendedProperties) {
            $c.properties | Add-Member -NotePropertyName extendedProperties -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $ep = $c.properties.extendedProperties

        $needsAppId = (-not $ep.PSObject.Properties['appId']) -or [string]::IsNullOrWhiteSpace("$($ep.appId)")
        $needsArm   = (-not $ep.PSObject.Properties['armResourceId']) -or [string]::IsNullOrWhiteSpace("$($ep.armResourceId)")
        $needsName  = (-not $ep.PSObject.Properties['resource']) -or (-not $ep.resource.PSObject.Properties['name']) -or [string]::IsNullOrWhiteSpace("$($ep.resource.name)")

        if ($needsAppId) {
            Write-Log "  resolving AppInsights AppId for connector '$($c.name)'"
            $appId = az resource show --ids $aiId --query 'properties.AppId' -o tsv 2>$null
            if ([string]::IsNullOrWhiteSpace($appId)) {
                Write-Error "Could not resolve AppId for AppInsights resource: $aiId. Ensure UAMI/principal has Reader on this resource."
                exit 1
            }
            $ep | Add-Member -NotePropertyName appId -NotePropertyValue $appId -Force
            $changed = $true
        }
        if ($needsArm) {
            $ep | Add-Member -NotePropertyName armResourceId -NotePropertyValue $aiId -Force
            $changed = $true
        }
        if ($needsName) {
            $resName = ($aiId -split '/')[-1]
            $ep | Add-Member -NotePropertyName resource -NotePropertyValue ([pscustomobject]@{ name = $resName }) -Force
            $changed = $true
        }
    }
    if ($changed) {
        $connectors = ($connArr | ConvertTo-Json -Depth 32 -Compress)
        # Single-element arrays: ConvertTo-Json may emit an object — re-wrap.
        if ($connectors -notmatch '^\s*\[') { $connectors = "[$connectors]" }
        Write-Log 'AppInsights connectors enriched (appId/armResourceId/resource.name auto-resolved)'
    }
}

$totalConn = $connectors | jq 'length'
Write-Log "Total: $totalConn connector(s)"

# ═══════ Read config/ ═══════

Write-Info 'Assembling config/'

# Skills — read JSON, resolve .md file references
$rawSkills = Collect-Config 'skills'
$skills    = Resolve-FileRefs $rawSkills $ConfigDir
Write-Log "skills: $($skills | jq 'length')"

# Subagents — read JSON, resolve .md file references
$rawSubagents = Collect-Config 'subagents'
$subagents    = Resolve-FileRefs $rawSubagents $ConfigDir
Write-Log "subagents: $($subagents | jq 'length')"

# Simple config arrays (no file refs needed)
$tools = Collect-Config 'tools'
Write-Log "tools: $($tools | jq 'length')"

$hooks = Collect-Config 'hooks'
Write-Log "hooks: $($hooks | jq 'length')"

$rawPrompts    = Collect-Config 'common-prompts'
$commonPrompts = Resolve-FileRefs $rawPrompts $ConfigDir
Write-Log "common-prompts: $($commonPrompts | jq 'length')"

$scheduledTasks = Collect-Config 'scheduled-tasks'
Write-Log "scheduled-tasks: $($scheduledTasks | jq 'length')"

$incidentFilters = Collect-Config 'incident-filters'
Write-Log "incident-filters: $($incidentFilters | jq 'length')"

$httpTriggers = Collect-Config 'http-triggers'
Write-Log "http-triggers: $($httpTriggers | jq 'length')"

$pluginConfigs = Collect-Config 'plugin-configs'
Write-Log "plugin-configs: $($pluginConfigs | jq 'length')"

$incidentPlatforms = Resolve-EnvVars (Collect-Config 'incident-platforms')
Write-Log "incident-platforms: $($incidentPlatforms | jq 'length')"

$repos = Collect-Config 'repos'
Write-Log "repos: $($repos | jq 'length')"

$marketplaces = '[]'
if (Test-Path (Join-Path $ConfigDir 'config/plugins/marketplaces') -PathType Container) {
    $marketplaces = Collect-Config 'plugins/marketplaces'
}
$installations = '[]'
if (Test-Path (Join-Path $ConfigDir 'config/plugins/installations') -PathType Container) {
    $installations = Collect-Config 'plugins/installations'
}

# ═══════ Read data/ ═══════

Write-Info 'Reading data/'

$knowledge      = '[]'
$knowledgeItems = '[]'
$synthKnowledge = '[]'
$synthKnowledgeDir = ''
$repoInstructions = '[]'

$dataDir = Join-Path $ConfigDir 'data'

if (Test-Path (Join-Path $dataDir 'knowledge.json') -PathType Leaf) {
    $knowledge = Get-Content (Join-Path $dataDir 'knowledge.json') -Raw
}
if (Test-Path (Join-Path $dataDir 'knowledge-items.json') -PathType Leaf) {
    $knowledgeItems = Get-Content (Join-Path $dataDir 'knowledge-items.json') -Raw
}
if (Test-Path (Join-Path $dataDir 'synthesized-knowledge.json') -PathType Leaf) {
    $synthKnowledge = Get-Content (Join-Path $dataDir 'synthesized-knowledge.json') -Raw
}
$synthDir = Join-Path $dataDir 'synthesized-knowledge'
if (Test-Path $synthDir -PathType Container) {
    $synthKnowledgeDir = (Resolve-Path $synthDir).Path
    $skCount = (Get-ChildItem $synthDir -File -Recurse | Measure-Object).Count
    Write-Log "Found $skCount synthesized knowledge file(s) in data/synthesized-knowledge/"
}
if (Test-Path (Join-Path $dataDir 'repo-instructions.json') -PathType Leaf) {
    $repoInstructions = Get-Content (Join-Path $dataDir 'repo-instructions.json') -Raw
}

# Auto-discover .md files in data/ and data/knowledge/ → convert to knowledge items for upload
$mdFiles = @()
if (Test-Path $dataDir -PathType Container) {
    $mdFiles += Get-ChildItem $dataDir -Filter '*.md' -File -ErrorAction SilentlyContinue
}
$knowledgeSubdir = Join-Path $dataDir 'knowledge'
if (Test-Path $knowledgeSubdir -PathType Container) {
    $mdFiles += Get-ChildItem $knowledgeSubdir -Filter '*.md' -File -ErrorAction SilentlyContinue
}

if ($mdFiles.Count -gt 0) {
    Write-Log "Found $($mdFiles.Count) knowledge .md file(s) in data/"
    foreach ($mdf in $mdFiles) {
        $fname   = $mdf.Name
        $content = Get-Content $mdf.FullName -Raw
        $knowledgeItems = $knowledgeItems | jq -c --arg name $fname --arg content $content `
            '. + [{"name": $name, "type": "KnowledgeText", "content": $content}]'
    }
}

$kLen  = $knowledge      | jq 'length'
$kiLen = $knowledgeItems | jq 'length'
Write-Log "knowledge: $kLen, items: $kiLen"

# ═══════ Write parameters.json (Bicep) ═══════

Write-Info "Writing $ParamsFile"

# Helper: read a property off a PSObject (or hashtable) with a default; works in StrictMode
function Get-Prop {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) {
            $v = $Obj[$Name]
            if ($null -ne $v) { return $v }
        }
        return $Default
    }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

# Helper: emit an empty object as {} not null when ConvertTo-Json sees an empty PSObject
function Ensure-Obj { param($v) if ($null -eq $v) { return @{} } else { return $v } }

# Helper: emit empty array consistently
function Ensure-Arr { param($v) if ($null -eq $v) { return @() } else { return ,$v } }

# Parse JSON-string vars into native objects
$togglesObj         = ($toggles         | ConvertFrom-Json -ErrorAction SilentlyContinue)
$ctogObj            = ($connectorToggles | ConvertFrom-Json -ErrorAction SilentlyContinue)
$tagsObj            = ($tags            | ConvertFrom-Json -ErrorAction SilentlyContinue)
$targetRgsArr       = @(($targetRgs     | ConvertFrom-Json -ErrorAction SilentlyContinue))
$connectorsArr      = @(($connectors    | ConvertFrom-Json -ErrorAction SilentlyContinue))
$toolsArr           = @(($tools         | ConvertFrom-Json -ErrorAction SilentlyContinue))
$skillsArr          = @(($skills        | ConvertFrom-Json -ErrorAction SilentlyContinue))
$subagentsArr       = @(($subagents     | ConvertFrom-Json -ErrorAction SilentlyContinue))
$commonPromptsArr   = @(($commonPrompts | ConvertFrom-Json -ErrorAction SilentlyContinue))
$pluginConfigsArr   = @(($pluginConfigs | ConvertFrom-Json -ErrorAction SilentlyContinue))

# Filter: connectors going into the Bicep "connectors" array exclude KnowledgeFile (handled by extras)
$bicepConnectors = @($connectorsArr | Where-Object {
    $t = ''
    if ($null -ne $_) { $t = (Get-Prop (Get-Prop $_ 'properties') 'dataConnectorType' '') }
    $t -ne 'KnowledgeFile'
})

# Transform commonPrompts: {metadata, spec} → {name, type, tags, properties}
$commonPromptsArm = @($commonPromptsArr | ForEach-Object {
    [pscustomobject]@{
        name       = (Get-Prop (Get-Prop $_ 'metadata') 'name' (Get-Prop $_ 'name' ''))
        type       = (Get-Prop $_ 'type' 'CommonPrompt')
        tags       = @((Get-Prop $_ 'tags' @()))
        properties = (Ensure-Obj (Get-Prop $_ 'spec' (Get-Prop $_ 'properties' @{})))
    }
})

# Build the parameters object as a hashtable, then ConvertTo-Json (works on Windows + Linux pwsh)
$paramsObj = [ordered]@{
    '$schema'        = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    'contentVersion' = '1.0.0.0'
    'parameters'     = [ordered]@{
        'agentName'                   = @{ value = $agentName }
        'agentResourceGroupName'      = @{ value = $agentRg }
        'location'                    = @{ value = $agentLoc }
        'targetResourceGroups'        = @{ value = $targetRgsArr }
        'accessLevel'                 = @{ value = $access }
        'actionMode'                  = @{ value = $action }
        'upgradeChannel'              = @{ value = $upgradeChannel }
        'defaultModelProvider'        = @{ value = $modelProvider }
        'monthlyAgentUnitLimit'       = @{ value = [int]$monthlyLimit }
        'tags'                        = @{ value = (Ensure-Obj $tagsObj) }
        'existingManagedIdentityId'   = @{ value = $existingUami }
        'existingAgentAppInsightsId'  = @{ value = $existingAi }
        'enableAppInsightsConnector'  = @{ value = [bool](Get-Prop $ctogObj    'enableAppInsightsConnector'  $false) }
        'appInsightsResourceId'       = @{ value = [string](Get-Prop $ctogObj  'appInsightsResourceId'       '') }
        'appInsightsAppId'            = @{ value = [string](Get-Prop $ctogObj  'appInsightsAppId'            '') }
        'enableLogAnalyticsConnector' = @{ value = [bool](Get-Prop $ctogObj    'enableLogAnalyticsConnector' $false) }
        'lawResourceId'               = @{ value = [string](Get-Prop $ctogObj  'lawResourceId'               '') }
        'enableAzureMonitorConnector' = @{ value = [bool](Get-Prop $ctogObj    'enableAzureMonitorConnector' $false) }
        'azureMonitorLookbackDays'    = @{ value = [int](Get-Prop $ctogObj     'azureMonitorLookbackDays'    7) }
        'enableDailyHealthCheckTask'  = @{ value = [bool](Get-Prop $togglesObj 'enableDailyHealthCheckTask'  $false) }
        'enableDenyProdDeletesHook'   = @{ value = [bool](Get-Prop $togglesObj 'enableDenyProdDeletesHook'   $false) }
        'enableSafetyRulesPrompt'     = @{ value = [bool](Get-Prop $togglesObj 'enableSafetyRulesPrompt'     $false) }
        'enableWebhookBridge'         = @{ value = [bool](Get-Prop $togglesObj 'enableWebhookBridge'         $false) }
        'webhookBridgeTriggerUrl'     = @{ value = [string](Get-Prop $togglesObj 'webhookBridgeTriggerUrl'   '') }
        'connectors'                  = @{ value = $bicepConnectors }
        'tools'                       = @{ value = @() }  # deployed via data-plane (apply-extras)
        'skills'                      = @{ value = @() }  # deployed via data-plane (apply-extras)
        'subagents'                   = @{ value = @() }  # deployed via data-plane (apply-extras)
        'scheduledTasks'              = @{ value = @() }
        'incidentFilters'             = @{ value = @() }
        'commonPrompts'               = @{ value = @() }  # deployed via data-plane (apply-extras)
        'pluginConfigs'               = @{ value = @() }  # deployed via data-plane (apply-extras)
    }
}

$paramsObj | ConvertTo-Json -Depth 32 | Out-File -FilePath $ParamsFile -Encoding utf8NoBOM

$paramsSize = (Get-Item $ParamsFile).Length
Write-Log "Wrote $paramsSize bytes"

# ═══════ Write extras.json (data-plane) ═══════

Write-Info "Writing $ExtrasFile"

# Parse extras-only JSON-string vars
$reposArr             = @(($repos             | ConvertFrom-Json -ErrorAction SilentlyContinue))
$incidentPlatformsArr = @(($incidentPlatforms | ConvertFrom-Json -ErrorAction SilentlyContinue))
$incidentFiltersArr   = @(($incidentFilters   | ConvertFrom-Json -ErrorAction SilentlyContinue))
$scheduledTasksArr    = @(($scheduledTasks    | ConvertFrom-Json -ErrorAction SilentlyContinue))
$hooksArr             = @(($hooks             | ConvertFrom-Json -ErrorAction SilentlyContinue))
$httpTriggersArr      = @(($httpTriggers      | ConvertFrom-Json -ErrorAction SilentlyContinue))
$knowledgeArr         = @(($knowledge         | ConvertFrom-Json -ErrorAction SilentlyContinue))
$knowledgeItemsArr    = @(($knowledgeItems    | ConvertFrom-Json -ErrorAction SilentlyContinue))
$synthKnowledgeArr    = @(($synthKnowledge    | ConvertFrom-Json -ErrorAction SilentlyContinue))
$repoInstructionsArr  = @(($repoInstructions  | ConvertFrom-Json -ErrorAction SilentlyContinue))
$marketplacesArr      = @(($marketplaces      | ConvertFrom-Json -ErrorAction SilentlyContinue))
$installationsArr     = @(($installations     | ConvertFrom-Json -ErrorAction SilentlyContinue))

# Transform hooks: {metadata, spec} → {name, type, tags, properties}
$hooksArm = @($hooksArr | ForEach-Object {
    [pscustomobject]@{
        name       = (Get-Prop (Get-Prop $_ 'metadata') 'name' (Get-Prop $_ 'name' ''))
        type       = (Get-Prop $_ 'type' 'GlobalHook')
        tags       = @((Get-Prop $_ 'tags' @()))
        properties = (Ensure-Obj (Get-Prop $_ 'spec' (Get-Prop $_ 'properties' @{})))
    }
})

# commonPrompts already transformed above ($commonPromptsArm)
# Filter: connectors going into extras = only Mcp or KnowledgeFile types
$extrasConnectors = @($connectorsArr | Where-Object {
    $t = ''
    if ($null -ne $_) { $t = (Get-Prop (Get-Prop $_ 'properties') 'dataConnectorType' '') }
    $t -eq 'Mcp' -or $t -eq 'KnowledgeFile'
})

$extrasObj = [ordered]@{
    repos                  = $reposArr
    incidentPlatforms      = $incidentPlatformsArr
    incidentFilters        = $incidentFiltersArr
    scheduledTasks         = $scheduledTasksArr
    hooks                  = $hooksArm
    commonPrompts          = $commonPromptsArm
    skills                 = $skillsArr
    subagents              = $subagentsArr
    tools                  = $toolsArr
    pluginConfigs          = $pluginConfigsArr
    httpTriggers           = $httpTriggersArr
    knowledge              = $knowledgeArr
    knowledgeItems         = $knowledgeItemsArr
    synthesizedKnowledge   = $synthKnowledgeArr
    synthesizedKnowledgeDir = $synthKnowledgeDir
    repoInstructions       = $repoInstructionsArr
    plugins                = [ordered]@{
        marketplaces  = $marketplacesArr
        installations = $installationsArr
    }
    connectors             = $extrasConnectors
}

$extrasObj | ConvertTo-Json -Depth 32 | Out-File -FilePath $ExtrasFile -Encoding utf8NoBOM

# Merge admin settings if present (adminUsers for cross-tenant access)
$adminFile = Join-Path $ConfigDir 'admin-settings.json'
if (Test-Path $adminFile -PathType Leaf) {
    Write-Log 'Merging admin-settings.json (adminUsers) into extras'
    $existing = Get-Content $ExtrasFile -Raw | ConvertFrom-Json
    $admin    = Get-Content $adminFile -Raw  | ConvertFrom-Json
    $adminUsers = @((Get-Prop $admin 'adminUsers' @()))
    # Re-emit as ordered hashtable so we don't lose key ordering
    $merged = [ordered]@{}
    foreach ($p in $existing.PSObject.Properties) { $merged[$p.Name] = $p.Value }
    $merged['adminUsers'] = $adminUsers
    $merged | ConvertTo-Json -Depth 32 | Out-File -FilePath $ExtrasFile -Encoding utf8NoBOM
}

$extrasSize = (Get-Item $ExtrasFile).Length
Write-Log "Wrote $extrasSize bytes"

Write-Host ''
Write-Info 'Assembly complete'
Write-Host ''
Write-Host "  $ParamsFile  <- for deploy.sh (Bicep)"
Write-Host "  $ExtrasFile  <- for apply-extras.sh (data-plane)"
Write-Host ''
$subDisplay = if ($agentSub) { $agentSub } else { '$(az account show -q id -o tsv)' }
Write-Host "Deploy with:"
Write-Host "  ./deploy.sh $ParamsFile"
Write-Host "  ./apply-extras.sh $subDisplay $agentRg $agentName $ExtrasFile"
Write-Host ''
