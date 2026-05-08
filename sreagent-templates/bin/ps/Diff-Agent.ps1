<#
.SYNOPSIS
    Compare local config against a deployed SRE Agent.

.DESCRIPTION
    Shows what will be created, updated, or is unchanged.
    Useful before deploy to preview changes, or in CI/CD for review gates.

    Exit codes:
      0 = no changes (everything matches)
      1 = changes detected (prints diff table)
      2 = agent doesn't exist (all items will be created)

.PARAMETER Subscription
    Azure subscription ID.

.PARAMETER ResourceGroup
    Resource group containing the agent.

.PARAMETER AgentName
    Agent resource name.

.PARAMETER ConfigDir
    Path to the config directory to compare against.

.EXAMPLE
    .\Diff-Agent.ps1 -Subscription <sub> -ResourceGroup <rg> -AgentName <name> -ConfigDir /tmp/my-export
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Alias('s')]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [Alias('g')]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [Alias('n')]
    [string]$AgentName,

    [Parameter(Mandatory)]
    [Alias('c','d')]
    [string]$ConfigDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────── Prerequisites ───────────────────────────

$PrereqScript = Join-Path $PSScriptRoot 'Check-Prerequisites.ps1'
if (Test-Path $PrereqScript) {
    . $PrereqScript
    if (-not (Test-Prerequisites -IncludePython -IncludeCurl)) { exit 1 }
} else {
    foreach ($cmd in @('jq', 'az', 'curl', 'python3')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Write-Host "Error: $cmd is required but not found." -ForegroundColor Red
            exit 1
        }
    }
}

# ─────────────────────────── ARM setup ───────────────────────────

$API_VERSION = '2025-05-01-preview'
$ARM_BASE    = "https://management.azure.com/subscriptions/${Subscription}/resourceGroups/${ResourceGroup}/providers/Microsoft.App/agents/${AgentName}"

# ─────────────────────────── Check if agent exists ───────────────────────────

$AgentJson = az rest -m GET --url "${ARM_BASE}?api-version=${API_VERSION}" -o json 2>$null
if (-not $AgentJson) { $AgentJson = '{}' }

$Endpoint = $AgentJson | jq -r '.properties.agentEndpoint // empty' 2>$null
if (-not $Endpoint -or $Endpoint -eq 'null') {
    Write-Host "Agent '${AgentName}' does not exist in ${ResourceGroup}. All items will be CREATED." -ForegroundColor Yellow
    Write-Host ''

    # Count connectors from connectors.json
    $connFile = Join-Path $ConfigDir 'connectors.json'
    if (Test-Path $connFile) {
        foreach ($tog in @('enableLogAnalyticsConnector', 'enableAppInsightsConnector', 'enableAzureMonitorConnector')) {
            $v = Get-Content $connFile -Raw | jq -r ".toggles.${tog} // false" 2>$null
            if ($v -eq 'true') {
                $label = switch ($tog) {
                    'enableLogAnalyticsConnector' { 'Log Analytics (toggle)' }
                    'enableAppInsightsConnector'  { 'App Insights (toggle)' }
                    'enableAzureMonitorConnector'  { 'Azure Monitor (toggle)' }
                }
                Write-Host "    + connector: $label" -ForegroundColor Green
            }
        }
        $arrCt = Get-Content $connFile -Raw | jq -r '.connectors // [] | length' 2>$null
        if ([int]$arrCt -gt 0) {
            $cNames = Get-Content $connFile -Raw | jq -r '.connectors[].name' 2>$null
            foreach ($cname in ($cNames -split "`n" | Where-Object { $_ })) {
                $ctype = Get-Content $connFile -Raw | jq -r --arg n $cname '.connectors[] | select(.name==$n) | .properties.dataConnectorType' 2>$null
                Write-Host "    + connector: ${cname} (${ctype})" -ForegroundColor Green
            }
        }
    }

    # Check webhook bridge
    $agentFile = Join-Path $ConfigDir 'agent.json'
    if (Test-Path $agentFile) {
        $wh = Get-Content $agentFile -Raw | jq -r '.toggles.enableWebhookBridge // false' 2>$null
        if ($wh -eq 'true') {
            Write-Host '    + webhook bridge (Logic App)' -ForegroundColor Green
        }
    }

    # Count config/ items
    foreach ($d in @('skills', 'subagents', 'tools', 'hooks', 'common-prompts', 'plugin-configs', 'repos')) {
        $dir = Join-Path $ConfigDir "config/$d"
        if (Test-Path $dir) {
            $ct = (Get-ChildItem $dir -Filter '*.yaml' -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($ct -gt 0) { Write-Host "    + ${d}: ${ct} (new)" -ForegroundColor Green }
        }
    }
    foreach ($d in @('scheduled-tasks', 'incident-filters', 'http-triggers', 'incident-platforms')) {
        $dir = Join-Path $ConfigDir "automations/$d"
        if (Test-Path $dir) {
            $ct = (Get-ChildItem $dir -Filter '*.yaml' -ErrorAction SilentlyContinue | Measure-Object).Count
            if ($ct -gt 0) { Write-Host "    + ${d}: ${ct} (new)" -ForegroundColor Green }
        }
    }

    # Knowledge files
    $dataDir = Join-Path $ConfigDir 'data'
    if (Test-Path $dataDir) {
        $kct = (Get-ChildItem $dataDir -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($kct -gt 0) { Write-Host "    + knowledge: ${kct} file(s)" -ForegroundColor Green }
    }

    exit 2
}

# ─────────────────────────── Data-plane token ───────────────────────────

$Token = az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>$null
if (-not $Token) {
    Write-Host 'FAIL: Could not get data-plane token' -ForegroundColor Red
    exit 1
}

function Invoke-Dp {
    param([string]$Path)
    curl -sS "${Endpoint}${Path}" -H "Authorization: Bearer $Token" 2>$null
}

# ─────────────────────────── Results tracking ───────────────────────────

$Creates   = 0
$Orphans   = 0
$Unchanged = 0
$Results   = [System.Collections.Generic.List[PSCustomObject]]::new()

# ─────────────────────────── Helper: read YAML name via python3 ───────────────────────────

function Get-YamlName {
    param([string]$FilePath)
    python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('metadata',{}).get('name','') or d.get('name',''))" $FilePath 2>$null
}

# ─────────────────────────── compare_items ───────────────────────────

function Compare-Items {
    param(
        [string]$Label,
        [string]$LocalDir,
        [string[]]$DeployedNames
    )

    $configNames = @()
    if (Test-Path $LocalDir) {
        foreach ($f in Get-ChildItem $LocalDir -Filter '*.yaml' -ErrorAction SilentlyContinue) {
            $name = Get-YamlName $f.FullName
            if ($name) { $configNames += $name }
        }
    }

    foreach ($name in $configNames) {
        if ($DeployedNames -contains $name) {
            $script:Results.Add([PSCustomObject]@{ Resource = "${Label}/${name}"; Action = '= match' })
            $script:Unchanged++
        }
        else {
            $script:Results.Add([PSCustomObject]@{ Resource = "${Label}/${name}"; Action = '+ CREATE' })
            $script:Creates++
        }
    }

    # Orphans: deployed but not in config
    foreach ($name in $DeployedNames) {
        if (-not $name) { continue }
        if ($configNames -notcontains $name) {
            $script:Results.Add([PSCustomObject]@{ Resource = "${Label}/${name}"; Action = '- ORPHAN (deployed, not in config)' })
            $script:Orphans++
            $script:Unchanged++
        }
    }
}

# ─────────────────────────── Banner ───────────────────────────

Write-Host ''
Write-Host ([char]0x2550 * 55) -ForegroundColor Cyan
Write-Host "  Change Detection: ${AgentName} in ${ResourceGroup}" -ForegroundColor Cyan
Write-Host ([char]0x2550 * 55) -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────── Skills ───────────────────────────

$deployedSkills = @(Invoke-Dp '/api/v1/extendedAgent/skills' | jq -r '(if type == "array" then . elif .value then .value else [] end)[].name' 2>$null | Where-Object { $_ })
Compare-Items 'skills' (Join-Path $ConfigDir 'config/skills') $deployedSkills

# ─────────────────────────── Subagents ───────────────────────────

$deployedSA = @(Invoke-Dp '/api/v2/extendedAgent/agents' | jq -r '.value[].name' 2>$null | Where-Object { $_ })
Compare-Items 'subagents' (Join-Path $ConfigDir 'config/subagents') $deployedSA

# ─────────────────────────── Hooks ───────────────────────────

$deployedHooks = @(Invoke-Dp '/api/v2/extendedAgent/hooks' | jq -r '(.value // .)[].name' 2>$null | Where-Object { $_ })
Compare-Items 'hooks' (Join-Path $ConfigDir 'config/hooks') $deployedHooks

# ─────────────────────────── Common Prompts ───────────────────────────

$deployedPrompts = @(Invoke-Dp '/api/v2/extendedAgent/commonprompts' | jq -r '(.value // .)[].name' 2>$null | Where-Object { $_ })
Compare-Items 'common-prompts' (Join-Path $ConfigDir 'config/common-prompts') $deployedPrompts

# ─────────────────────────── Scheduled Tasks ───────────────────────────

$deployedTasks = @(Invoke-Dp '/api/v1/scheduledtasks' | jq -r '.[].name' 2>$null | Sort-Object -Unique | Where-Object { $_ })
Compare-Items 'scheduled-tasks' (Join-Path $ConfigDir 'automations/scheduled-tasks') $deployedTasks

# ─────────────────────────── Incident Filters (deep compare) ───────────────────────────

$deployedFiltersJson  = Invoke-Dp '/api/v1/incidentPlayground/filters' 2>$null
if (-not $deployedFiltersJson) { $deployedFiltersJson = '[]' }
$deployedFilters      = @($deployedFiltersJson | jq -r '.[].id' 2>$null | Where-Object { $_ })
$deployedHandlersJson = Invoke-Dp '/api/v1/incidentPlayground/handlers' 2>$null
if (-not $deployedHandlersJson) { $deployedHandlersJson = '[]' }

$filterDir = Join-Path $ConfigDir 'automations/incident-filters'
if (Test-Path $filterDir) {
    foreach ($f in Get-ChildItem $filterDir -Filter '*.yaml' -ErrorAction SilentlyContinue) {
        $localName = Get-YamlName $f.FullName
        if (-not $localName) { continue }

        if ($deployedFilters -contains $localName) {
            # Deep field comparison
            $deployed = $deployedFiltersJson | jq -c --arg n $localName '[.[] | select(.id == $n)][0] // {}' 2>$null
            $localSpec = python3 -c @"
import yaml,json,sys
d=yaml.safe_load(open(sys.argv[1]))
s=d.get('spec',{})
for k in ['customInstructions','incidentPlatform','maxAutomatedInvestigationAttempts']:
    s.pop(k,None)
print(json.dumps(s))
"@ $f.FullName 2>$null

            $diffs = @()
            foreach ($key in @('agentMode', 'deepInvestigationEnabled', 'isEnabled')) {
                $localVal  = $localSpec  | jq -r --arg k $key '.[$k] // empty' 2>$null
                $deployVal = $deployed   | jq -r --arg k $key '.[$k] // empty' 2>$null
                if ($localVal -and $localVal -ne $deployVal) {
                    $diffs += "${key}:${deployVal}->${localVal}"
                }
            }

            # Check customInstructions via handler
            $localCi  = python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('spec',{}).get('customInstructions',''))" $f.FullName 2>$null
            $deployCi = $deployedHandlersJson | jq -r --arg n $localName '[.[] | select(.incidentFilterId == $n)][0].customInstructions // ""' 2>$null
            if ($localCi -and $localCi -ne $deployCi) {
                $diffs += 'customInstructions:changed'
            }

            if ($diffs.Count -gt 0) {
                $diffStr = $diffs -join ' '
                $Results.Add([PSCustomObject]@{ Resource = "incident-filters/${localName}"; Action = "~ UPDATE ($diffStr)" })
                $Creates++
            }
            else {
                $Results.Add([PSCustomObject]@{ Resource = "incident-filters/${localName}"; Action = '= match' })
                $Unchanged++
            }
        }
        else {
            $Results.Add([PSCustomObject]@{ Resource = "incident-filters/${localName}"; Action = '+ CREATE' })
            $Creates++
        }
    }

    # Orphans: deployed filters not in local config
    foreach ($name in $deployedFilters) {
        if (-not $name) { continue }
        $found = $false
        foreach ($f in Get-ChildItem $filterDir -Filter '*.yaml' -ErrorAction SilentlyContinue) {
            $n = Get-YamlName $f.FullName
            if ($n -eq $name) { $found = $true; break }
        }
        if (-not $found) {
            $Results.Add([PSCustomObject]@{ Resource = "incident-filters/${name}"; Action = '- ORPHAN (deployed, not in config)' })
            $Orphans++
            $Unchanged++
        }
    }
}

# ─────────────────────────── Repos ───────────────────────────

$deployedRepos = @(Invoke-Dp '/api/v2/repos' | jq -r '(.value // .)[].name' 2>$null | Where-Object { $_ })
Compare-Items 'repos' (Join-Path $ConfigDir 'config/repos') $deployedRepos

# ─────────────────────────── Connectors (toggle-based count check) ───────────────────────────

$deployedConnRaw = az rest -m GET --url "${ARM_BASE}/DataConnectors?api-version=${API_VERSION}" --query 'value[].name' -o tsv 2>$null
$deployedConnCt  = @($deployedConnRaw -split "`n" | Where-Object { $_ }).Count

$connFile = Join-Path $ConfigDir 'connectors.json'
$configConnCt = 0
if (Test-Path $connFile) {
    $configConnCt = Get-Content $connFile -Raw | jq '.toggles | to_entries | map(select(.key | startswith("enable")) | select(.value == true)) | length' 2>$null
    if (-not $configConnCt) { $configConnCt = 0 }
}

if ([int]$configConnCt -eq [int]$deployedConnCt) {
    $Results.Add([PSCustomObject]@{ Resource = 'connectors'; Action = "= ${deployedConnCt} connector(s) — no change" })
}
else {
    $Results.Add([PSCustomObject]@{ Resource = 'connectors'; Action = "~ ${deployedConnCt} deployed -> ${configConnCt} in config" })
}

# ─────────────────────────── Print results table ───────────────────────────

$fmt = '  {0,-40} {1}'
Write-Host ($fmt -f 'Resource', 'Action')
Write-Host ($fmt -f ([string][char]0x2500 * 40), ([string][char]0x2500 * 10))

foreach ($r in $Results) {
    $color = if     ($r.Action -match '^\+ CREATE')  { 'Green' }
             elseif ($r.Action -match '^\- ORPHAN')   { 'Yellow' }
             elseif ($r.Action -match '^\~ UPDATE')   { 'Magenta' }
             elseif ($r.Action -match '^\~')          { 'Magenta' }
             else                                     { 'Gray' }
    Write-Host ($fmt -f $r.Resource, $r.Action) -ForegroundColor $color
}

# ─────────────────────────── Summary ───────────────────────────

Write-Host ''
Write-Host ([char]0x2550 * 55) -ForegroundColor Cyan
Write-Host "  Summary: ${Creates} new, ${Unchanged} match, ${Orphans} orphan" -ForegroundColor $(if ($Creates -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ([char]0x2550 * 55) -ForegroundColor Cyan
Write-Host ''

if ($Creates -gt 0) { exit 1 }
exit 0
