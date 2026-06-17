<#
.SYNOPSIS
    Add a recipe's components to an existing agent directory (non-destructive merge).

.DESCRIPTION
    Augments an existing agent with a recipe's config files. Auto-detects values
    already configured (DT, LAW, GitHub repo, etc.) — only prompts for missing values.

    Does NOT overwrite agent.json identity/access/model — only merges toggles.
    Does NOT duplicate connectors — skips if connector name already exists.

.EXAMPLE
    ./Add-Recipe.ps1 -Recipe law-dynatrace-github-httptrigger-prvalidation -AgentDir ./demo1-dt-snow
    ./Add-Recipe.ps1 -Recipe law-dynatrace-github-httptrigger-prvalidation -AgentDir ./demo1-dt-snow -NonInteractive
    ./Add-Recipe.ps1 -Recipe law-dynatrace-github-httptrigger-prvalidation -AgentDir ./demo1-dt-snow -Set @{githubRepo='org/repo'}

.NOTES
    After adding:
      ./Deploy-Agent.ps1 <agent-dir>
#>
[CmdletBinding()]
param(
    [Alias("r")]
    [string]$Recipe,

    [Parameter(Mandatory)]
    [string]$AgentDir,

    [switch]$List,

    [Parameter()]
    $Set,

    [switch]$NonInteractive,

    [switch]$NoTelemetry
)

Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$BinDir = Split-Path $ScriptDir -Parent
$RecipesDir = Join-Path (Split-Path $BinDir -Parent) 'recipes'

# Dot-source prereq checker + jq wrapper
. (Join-Path $ScriptDir 'Check-Prerequisites.ps1')
if (-not (Test-Prerequisites)) { exit 1 }
. (Join-Path $ScriptDir 'Invoke-Jq.ps1')

# ─────────────────────────── Parse -Set into hashtable ───────────────────────────

$Presets = @{}
if ($Set) {
    if ($Set -is [hashtable]) {
        $Presets = $Set.Clone()
    }
    elseif ($Set -is [string[]]) {
        foreach ($item in $Set) {
            $eqIdx = $item.IndexOf('=')
            if ($eqIdx -gt 0) {
                $Presets[$item.Substring(0, $eqIdx)] = $item.Substring($eqIdx + 1)
            }
            else { Write-Error "Invalid -Set value: '$item'. Expected key=value." }
        }
    }
    elseif ($Set -is [string]) {
        foreach ($item in $Set -split ',') {
            $item = $item.Trim()
            $eqIdx = $item.IndexOf('=')
            if ($eqIdx -gt 0) {
                $Presets[$item.Substring(0, $eqIdx)] = $item.Substring($eqIdx + 1)
            }
            elseif ($item -ne '') { Write-Error "Invalid -Set value: '$item'. Expected key=value." }
        }
    }
    else { Write-Error "-Set must be a hashtable, string array, or comma-separated string." }
}

# ─────────────────────────── List recipes ───────────────────────────

if ($List) {
    Write-Host 'Available recipes:' -ForegroundColor Cyan
    Write-Host ''
    foreach ($d in Get-ChildItem -Path $RecipesDir -Directory -ErrorAction SilentlyContinue) {
        $aj = Join-Path $d.FullName 'agent.json'
        if (Test-Path $aj) {
            $desc = Invoke-Jq -Raw -Filter '._description // "No description"' -InputFile $aj
            Write-Host "  $($d.Name.PadRight(45)) $desc"
        }
    }
    exit 0
}

# ─────────────────────────── Validate inputs ───────────────────────────

if (-not $Recipe) { Write-Error '-Recipe is required. Run with -List to see available recipes.' }

$RecipeDir = Join-Path $RecipesDir $Recipe
if (-not (Test-Path $RecipeDir -PathType Container)) {
    Write-Error "Recipe not found: $Recipe`nRun with -List to see available recipes."
}
$RecipeAgentJson = Join-Path $RecipeDir 'agent.json'
if (-not (Test-Path $RecipeAgentJson)) { Write-Error "Recipe missing agent.json: $Recipe" }

$AgentDir = (Resolve-Path $AgentDir -ErrorAction Stop).Path
$AgentAgentJson = Join-Path $AgentDir 'agent.json'
if (-not (Test-Path $AgentAgentJson)) { Write-Error "Not an agent directory (no agent.json): $AgentDir" }

Write-Host ''
Write-Host "── Adding recipe: $Recipe → $AgentDir ──" -ForegroundColor Cyan
Invoke-Jq -Raw -Filter '._description // ""' -InputFile $RecipeAgentJson | ForEach-Object { Write-Host $_ }
Write-Host ''

# ─────────────────────────── Auto-detect existing values ───────────────────────────

Write-Host '── Auto-detecting existing agent configuration ──' -ForegroundColor Cyan

function Auto-Set([string]$Key, [string]$Value) {
    if ($Value -and -not $Presets.ContainsKey($Key)) {
        $Presets[$Key] = $Value
        Write-Host "  auto: $Key = $Value"
    }
}

# Identity from agent.json
Auto-Set 'agentName'      (Invoke-Jq -Raw -Filter '.identity.agentName // ""' -InputFile $AgentAgentJson)
Auto-Set 'resourceGroup'  (Invoke-Jq -Raw -Filter '.identity.resourceGroup // ""' -InputFile $AgentAgentJson)
Auto-Set 'location'       (Invoke-Jq -Raw -Filter '.identity.location // ""' -InputFile $AgentAgentJson)

# LAW and Dynatrace from connectors.json
$ConnectorsFile = Join-Path $AgentDir 'connectors.json'
if (Test-Path $ConnectorsFile) {
    Auto-Set 'lawId' (Invoke-Jq -Raw -Filter '.toggles.lawResourceId // ""' -InputFile $ConnectorsFile)

    $dtEndpoint = Invoke-Jq -Raw -Filter '.connectors[]? | select(.name == "dynatrace") | .properties.extendedProperties.endpoint // ""' -InputFile $ConnectorsFile 2>$null
    if ($dtEndpoint -match 'https://([^.]+)\.apps\.dynatrace\.com') {
        Auto-Set 'dtTenant' $Matches[1]
    }
}

# Dynatrace token from secrets
$SecretsFile = Join-Path $AgentDir 'connectors.secrets.env'
if (Test-Path $SecretsFile) {
    $dtTokenLine = Get-Content $SecretsFile | Where-Object { $_ -match '^DYNATRACE_BEARER_TOKEN=' } | Select-Object -First 1
    if ($dtTokenLine) {
        Auto-Set 'dtToken' ($dtTokenLine -replace '^DYNATRACE_BEARER_TOKEN=', '')
    }
}

# GitHub repo from config/repos
$ReposDir = Join-Path $AgentDir 'config/repos'
if (Test-Path $ReposDir) {
    foreach ($rf in Get-ChildItem -Path $ReposDir -Filter '*.yaml' -ErrorAction SilentlyContinue) {
        $urlLine = Get-Content $rf.FullName | Where-Object { $_ -match 'url:' } | Select-Object -First 1
        if ($urlLine -match 'url:\s*"?([^"]+)"?' -and $Matches[1] -notmatch '\{\{') {
            Auto-Set 'githubRepo' $Matches[1].Trim()
            break
        }
    }
}

Write-Host ''

# ─────────────────────────── Collect remaining inputs ───────────────────────────

$promptsRaw = Invoke-Jq -Compact -Filter '._prompts // {}' -InputFile $RecipeAgentJson
if (-not $promptsRaw) { $promptsRaw = '{}' }
$Prompts = $promptsRaw | ConvertFrom-Json
$PromptKeys = Invoke-Jq -Raw -Filter '._prompts // {} | keys[]' -InputFile $RecipeAgentJson
$Values = @{}

foreach ($key in $PromptKeys) {
    # Skip identity fields
    if ($key -in @('agentName', 'resourceGroup', 'location', 'targetRGs', 'existingUamiId', 'modelProvider', 'existingAgentAppInsightsId')) {
        if ($Presets.ContainsKey($key)) { $Values[$key] = $Presets[$key] }
        continue
    }

    # Already auto-detected or preset
    if ($Presets.ContainsKey($key)) {
        $Values[$key] = $Presets[$key]
        continue
    }

    $promptDef = $Prompts.$key
    $ask = if ($promptDef.PSObject.Properties['ask']) { $promptDef.ask } else { $key }
    $default = if ($promptDef.PSObject.Properties['default'] -and $null -ne $promptDef.default) { "$($promptDef.default)" } else { '' }
    $required = if ($promptDef.PSObject.Properties['required'] -and $promptDef.required -eq $true) { $true } else { $false }
    $isSecret = if ($promptDef.PSObject.Properties['secret'] -and $promptDef.secret -eq $true) { $true } else { $false }

    if ($NonInteractive) {
        if ($default -ne '') {
            $Values[$key] = $default
            Write-Host "  ${ask}: $default (default)"
        }
        elseif ($required) {
            Write-Error "${key} is required, not auto-detected, and -NonInteractive set. Use -Set @{${key}='<value>'}"
        }
        continue
    }

    $prompt = "  ${ask}"
    if ($default) { $prompt += " ($default)" }
    $prompt += ': '

    if ($isSecret) {
        $val = Read-Host $prompt -AsSecureString
        $val = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($val))
    }
    else { $val = Read-Host $prompt }

    if (-not $val) { $val = $default }
    if (-not $val -and $required) { Write-Error "${key} is required." }
    $Values[$key] = $val
}

# ─────────────────────────── Copy config files (additive) ───────────────────────────

$Added = 0; $Skipped = 0

function Copy-DirAdditive([string]$SrcDir, [string]$DstDir, [string]$Label) {
    if (-not (Test-Path $SrcDir -PathType Container)) { return }
    if (-not (Test-Path $DstDir)) { New-Item -ItemType Directory -Path $DstDir -Force | Out-Null }
    foreach ($f in Get-ChildItem -Path $SrcDir -File) {
        $dst = Join-Path $DstDir $f.Name
        if (Test-Path $dst) {
            Write-Host "  skip $Label/$($f.Name) (already exists)"
            $script:Skipped++
        }
        else {
            Copy-Item $f.FullName $dst
            Write-Host "  add  $Label/$($f.Name)"
            $script:Added++
        }
    }
}

Write-Host ''
Write-Host '── Copying config files ──' -ForegroundColor Cyan
Copy-DirAdditive (Join-Path $RecipeDir 'config/skills')         (Join-Path $AgentDir 'config/skills')         'config/skills'
Copy-DirAdditive (Join-Path $RecipeDir 'config/subagents')      (Join-Path $AgentDir 'config/subagents')      'config/subagents'
Copy-DirAdditive (Join-Path $RecipeDir 'config/hooks')          (Join-Path $AgentDir 'config/hooks')          'config/hooks'
Copy-DirAdditive (Join-Path $RecipeDir 'config/common-prompts') (Join-Path $AgentDir 'config/common-prompts') 'config/common-prompts'
Copy-DirAdditive (Join-Path $RecipeDir 'config/repos')          (Join-Path $AgentDir 'config/repos')          'config/repos'
Copy-DirAdditive (Join-Path $RecipeDir 'config/tools')          (Join-Path $AgentDir 'config/tools')          'config/tools'
Copy-DirAdditive (Join-Path $RecipeDir 'config/plugin-configs') (Join-Path $AgentDir 'config/plugin-configs') 'config/plugin-configs'

Write-Host ''
Write-Host '── Copying automations ──' -ForegroundColor Cyan
Copy-DirAdditive (Join-Path $RecipeDir 'automations/http-triggers')      (Join-Path $AgentDir 'automations/http-triggers')      'automations/http-triggers'
Copy-DirAdditive (Join-Path $RecipeDir 'automations/scheduled-tasks')    (Join-Path $AgentDir 'automations/scheduled-tasks')    'automations/scheduled-tasks'
Copy-DirAdditive (Join-Path $RecipeDir 'automations/incident-filters')   (Join-Path $AgentDir 'automations/incident-filters')   'automations/incident-filters'
Copy-DirAdditive (Join-Path $RecipeDir 'automations/incident-platforms') (Join-Path $AgentDir 'automations/incident-platforms') 'automations/incident-platforms'

# ─────────────────────────── Merge toggles into agent.json ───────────────────────────

Write-Host ''
Write-Host '── Merging toggles into agent.json ──' -ForegroundColor Cyan

$recipeToggles = Invoke-Jq -Compact -Filter '.toggles // {}' -InputFile $RecipeAgentJson
if ($recipeToggles -and $recipeToggles -ne '{}') {
    $tmpAgentJson = "$AgentAgentJson.tmp"
    Invoke-Jq -Raw -Filter ". as `$root | `$root | .toggles = (.toggles // {} | . * $recipeToggles)" -InputFile $AgentAgentJson | Set-Content $tmpAgentJson -NoNewline
    Move-Item $tmpAgentJson $AgentAgentJson -Force
    $toggleKeys = Invoke-Jq -Raw -Filter '.toggles // {} | keys | join(", ")' -InputFile $RecipeAgentJson
    Write-Host "  merged toggles: $toggleKeys"
}
else { Write-Host '  no toggles to merge' }

# ─────────────────────────── Append connectors ───────────────────────────

$RecipeConnJson = Join-Path $RecipeDir 'connectors.json'
if (Test-Path $RecipeConnJson) {
    Write-Host ''
    Write-Host '── Merging connectors ──' -ForegroundColor Cyan

    $AgentConnJson = Join-Path $AgentDir 'connectors.json'

    # Merge connector toggles
    $recipeConnToggles = Invoke-Jq -Compact -Filter '.toggles // {}' -InputFile $RecipeConnJson
    if ($recipeConnToggles -and $recipeConnToggles -ne '{}' -and (Test-Path $AgentConnJson)) {
        $tmp = "$AgentConnJson.tmp"
        Invoke-Jq -Raw -Filter ". as `$root | `$root | .toggles = (.toggles // {} | . * $recipeConnToggles)" -InputFile $AgentConnJson | Set-Content $tmp -NoNewline
        Move-Item $tmp $AgentConnJson -Force
        Write-Host '  merged connector toggles'
    }

    # Append new connectors (skip duplicates by name)
    $recipeConns = Invoke-Jq -Compact -Filter '.connectors // []' -InputFile $RecipeConnJson
    if ($recipeConns -and $recipeConns -ne '[]') {
        $existingNames = @(Invoke-Jq -Raw -Filter '.connectors // [] | .[].name' -InputFile $AgentConnJson 2>$null)
        $newConns = @()
        foreach ($conn in ($recipeConns | ConvertFrom-Json)) {
            if ($existingNames -contains $conn.name) {
                Write-Host "  skip connector: $($conn.name) (already exists)"
            }
            else {
                $newConns += $conn
                Write-Host "  add  connector: $($conn.name)"
            }
        }
        if ($newConns.Count -gt 0) {
            $newConnsJson = $newConns | ConvertTo-Json -Compress -Depth 10
            if ($newConns.Count -eq 1) { $newConnsJson = "[$newConnsJson]" }
            $tmp = "$AgentConnJson.tmp"
            Invoke-Jq -Raw -Filter ".connectors = (.connectors // [] | . + $newConnsJson)" -InputFile $AgentConnJson | Set-Content $tmp -NoNewline
            Move-Item $tmp $AgentConnJson -Force
        }
    }
}

# ─────────────────────────── Replace placeholders in new files ───────────────────────────

if ($Values.Count -gt 0) {
    Write-Host ''
    Write-Host '── Replacing placeholders ──' -ForegroundColor Cyan
    $files = Get-ChildItem -Path $AgentDir -Recurse -Include '*.json', '*.yaml', '*.md' -File
    foreach ($file in $files) {
        $content = Get-Content $file.FullName -Raw
        $changed = $false
        foreach ($kv in $Values.GetEnumerator()) {
            $placeholder = "{{$($kv.Key)}}"
            $boolPlaceholder = "`"{{$($kv.Key):bool}}`""
            if ($content -match [regex]::Escape($placeholder) -or $content -match [regex]::Escape($boolPlaceholder)) {
                $boolVal = if ($kv.Value) { 'true' } else { 'false' }
                $content = $content -replace [regex]::Escape($boolPlaceholder), $boolVal
                $content = $content -replace [regex]::Escape($placeholder), $kv.Value
                $changed = $true
            }
        }
        if ($changed) {
            $content | Set-Content $file.FullName -NoNewline
            Write-Host "  replaced placeholders in $($file.Name)"
        }
    }
}

# ─────────────────────────── Write secrets ───────────────────────────

$SecretsEnv = Join-Path $AgentDir 'connectors.secrets.env'
foreach ($kv in $Values.GetEnumerator()) {
    $promptDef = $Prompts.($kv.Key)
    $isSecret = $promptDef -and $promptDef.PSObject.Properties['secret'] -and $promptDef.secret -eq $true
    if ($isSecret -and $kv.Value) {
        switch ($kv.Key) {
            'dtToken' {
                if (-not (Test-Path $SecretsEnv) -or -not (Get-Content $SecretsEnv | Where-Object { $_ -match '^DYNATRACE_BEARER_TOKEN=' })) {
                    Add-Content -Path $SecretsEnv -Value "DYNATRACE_BEARER_TOKEN=$($kv.Value)"
                    Write-Host '  added DYNATRACE_BEARER_TOKEN to secrets'
                }
            }
        }
    }
}

# ─────────────────────────── Summary ───────────────────────────

Write-Host ''
Write-Host '── Done ──' -ForegroundColor Cyan
Write-Host "  Added: $Added files"
Write-Host "  Skipped: $Skipped files (already existed)"
Write-Host ''
Write-Host 'Next step:'
Write-Host "  ./bin/ps/Deploy-Agent.ps1 $AgentDir"
