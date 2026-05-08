<#
.SYNOPSIS
    Create a new SRE Agent config from a recipe template.

.DESCRIPTION
    Interactive setup: pick a recipe, answer prompts, get a ready-to-deploy directory.
    The output uses the same directory layout as export-agent.sh, so you can
    assemble + deploy, or use clone-agent.sh to validate + deploy.

.EXAMPLE
    ./New-Agent.ps1                                           # Interactive — lists recipes
    ./New-Agent.ps1 -Recipe generic                           # Skip recipe picker
    ./New-Agent.ps1 -Recipe dynatrace -Output my-dt-agent     # With output dir
    ./New-Agent.ps1 -Recipe generic -Set @{agentName='prod-agent'; location='swedencentral'}
    ./New-Agent.ps1 -Recipe generic -Set agentName=prod-agent,location=swedencentral

.NOTES
    After setup:
      ./deploy.sh <output-dir>/ --dry-run
      ./deploy.sh <output-dir>/
#>
[CmdletBinding()]
param(
    [Alias("r")]
    [string]$Recipe,

    [switch]$List,

    [Alias("o")]
    [string]$Output,

    [Parameter()]
    $Set,

    [switch]$NonInteractive,

    [switch]$NoTelemetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$BinDir = Split-Path $ScriptDir -Parent
$RecipesDir = Join-Path (Split-Path $BinDir -Parent) "recipes"

# Dot-source prereq checker + telemetry
. (Join-Path $ScriptDir "Check-Prerequisites.ps1")
if (-not (Test-Prerequisites -IncludePython)) { exit 1 }
. (Join-Path $ScriptDir "Telemetry.ps1")
if ($NoTelemetry) { $script:NoTelemetry = $true }

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
            else {
                Write-Error "Invalid -Set value: '$item'. Expected key=value."
            }
        }
    }
    elseif ($Set -is [string]) {
        foreach ($item in $Set -split ',') {
            $item = $item.Trim()
            $eqIdx = $item.IndexOf('=')
            if ($eqIdx -gt 0) {
                $Presets[$item.Substring(0, $eqIdx)] = $item.Substring($eqIdx + 1)
            }
            elseif ($item -ne '') {
                Write-Error "Invalid -Set value: '$item'. Expected key=value."
            }
        }
    }
    else {
        Write-Error "-Set must be a hashtable, string array of key=value pairs, or comma-separated key=value string."
    }
}

# ─────────────────────────── Helper: get recipe list ───────────────────────────

function Get-Recipes {
    $dirs = Get-ChildItem -Path $RecipesDir -Directory -ErrorAction SilentlyContinue
    $result = @()
    foreach ($d in $dirs) {
        $agentJson = Join-Path $d.FullName "agent.json"
        if (Test-Path $agentJson) {
            $desc = jq -r '._description // "No description"' $agentJson 2>$null
            $result += [PSCustomObject]@{
                Name        = $d.Name
                Path        = $d.FullName
                Description = $desc
            }
        }
    }
    return $result
}

# ─────────────────────────── List recipes ───────────────────────────

if ($List) {
    Write-Host "Available recipes:" -ForegroundColor Cyan
    Write-Host ""
    $recipes = Get-Recipes
    foreach ($r in $recipes) {
        $agentJson = Join-Path $r.Path "agent.json"
        $prereqs = jq -r '._prerequisites // [] | map("    - " + .) | join("\n")' $agentJson 2>$null
        Write-Host "  $($r.Name)" -ForegroundColor White
        Write-Host "    $($r.Description)"
        if ($prereqs) { Write-Host $prereqs }
        Write-Host ""
    }
    exit 0
}

# ─────────────────────────── Pick recipe ───────────────────────────

if (-not $Recipe) {
    Write-Host ""
    Write-Host ([char]0x250C + ([string][char]0x2500) * 46 + [char]0x2510) -ForegroundColor Cyan
    Write-Host "$([char]0x2502)       SRE Agent " -NoNewline -ForegroundColor Cyan
    Write-Host ([char]0x2014) -NoNewline -ForegroundColor Cyan
    Write-Host " New Agent Setup             $([char]0x2502)" -ForegroundColor Cyan
    Write-Host ([char]0x2514 + ([string][char]0x2500) * 46 + [char]0x2518) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Available recipes:" -ForegroundColor Cyan
    Write-Host ""

    $recipes = Get-Recipes
    for ($i = 0; $i -lt $recipes.Count; $i++) {
        $name = $recipes[$i].Name.PadRight(18)
        Write-Host "  $($i + 1)) $name $($recipes[$i].Description)"
    }
    Write-Host ""

    $pick = Read-Host "Pick a recipe [1-$($recipes.Count)]"
    $pickNum = 0
    if ([int]::TryParse($pick, [ref]$pickNum) -and $pickNum -ge 1 -and $pickNum -le $recipes.Count) {
        $Recipe = $recipes[$pickNum - 1].Name
    }
    else {
        Write-Error "Invalid selection."
    }
}

$RecipeDir = Join-Path $RecipesDir $Recipe
if (-not (Test-Path $RecipeDir -PathType Container)) {
    Write-Error "Recipe not found: $Recipe`nRun with -List to see available recipes."
}
$RecipeAgentJson = Join-Path $RecipeDir "agent.json"
if (-not (Test-Path $RecipeAgentJson)) {
    Write-Error "Recipe missing agent.json: $Recipe"
}

Write-Host ""
Write-Host "── Recipe: $Recipe ──" -ForegroundColor Cyan
jq -r '._description // ""' $RecipeAgentJson 2>$null | ForEach-Object { Write-Host $_ }
Write-Host ""

# ─────────────────────────── Collect inputs ───────────────────────────

$promptsRaw = jq -c '._prompts // {}' $RecipeAgentJson 2>$null
if (-not $promptsRaw) { $promptsRaw = '{}' }
$Prompts = $promptsRaw | ConvertFrom-Json
$PromptKeys = jq -r '._prompts // {} | keys[]' $RecipeAgentJson 2>$null
$Values = @{}

foreach ($key in $PromptKeys) {
    $promptDef = $Prompts.$key
    $ask = if ($promptDef.PSObject.Properties['ask']) { $promptDef.ask } else { $key }
    $default = if ($promptDef.PSObject.Properties['default'] -and $null -ne $promptDef.default) { "$($promptDef.default)" } else { "" }
    $options = if ($promptDef.PSObject.Properties['options'] -and $promptDef.options) { ($promptDef.options -join ", ") } else { "" }
    $required = if ($promptDef.PSObject.Properties['required'] -and $promptDef.required -eq $true) { $true } else { $false }
    $isSecret = if ($promptDef.PSObject.Properties['secret'] -and $promptDef.secret -eq $true) { $true } else { $false }

    # Use preset value if provided
    if ($Presets.ContainsKey($key)) {
        $Values[$key] = $Presets[$key]
        Write-Host "  ${ask}: $($Presets[$key]) (preset)"
        continue
    }

    # Non-interactive: use default
    if ($NonInteractive) {
        if ($default -ne "") {
            $Values[$key] = $default
            Write-Host "  ${ask}: $default (default)"
        }
        elseif ($required) {
            Write-Error "$key is required but no default and -NonInteractive set."
        }
        continue
    }

    # Interactive prompt
    $promptText = "  $ask"
    if ($options) { $promptText += " [$options]" }
    if ($default) { $promptText += " ($default)" }
    $promptText += ": "

    if ($isSecret) {
        $secureVal = Read-Host -Prompt $promptText -AsSecureString
        $val = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureVal)
        )
        Write-Host "  (hidden)"
    }
    else {
        $val = Read-Host -Prompt $promptText
    }

    # Apply default
    if ([string]::IsNullOrEmpty($val)) { $val = $default }

    # Validate required
    if ([string]::IsNullOrEmpty($val) -and $required) {
        Write-Error "$key is required."
    }

    $Values[$key] = $val
}

Write-Host ""

# ─────────────────────────── Resolve output dir ───────────────────────────

$AgentName = if ($Values.ContainsKey("agentName") -and $Values["agentName"]) {
    $Values["agentName"]
} else {
    "$Recipe-agent"
}

if (-not $Output) { $Output = Join-Path "." $AgentName }

Write-Host "── Creating agent config: $Output/ ──" -ForegroundColor Cyan
Write-Host ""

# ─────────────────────────── Copy + stamp template ───────────────────────────

# Copy entire recipe directory
if (-not (Test-Path $Output)) { $null = New-Item -ItemType Directory -Path $Output -Force }
Copy-Item -Path (Join-Path $RecipeDir "*") -Destination $Output -Recurse -Force

# Remove metadata fields from agent.json (they're template-only)
$outAgentJson = Join-Path $Output "agent.json"
$cleaned = jq 'del(._recipe, ._description, ._prerequisites, ._prompts)' $outAgentJson
if ($LASTEXITCODE -ne 0 -or -not $cleaned) {
    Write-Error "jq failed processing agent.json"; exit 1
}
$cleaned | Set-Content -Path $outAgentJson -Encoding UTF8

# Replace {{placeholders}} with user values in all JSON and YAML files
$templateFiles = Get-ChildItem -Path $Output -Recurse -Include "*.json", "*.yaml" -File
foreach ($file in $templateFiles) {
    $content = Get-Content -Path $file.FullName -Raw

    foreach ($kvp in $Values.GetEnumerator()) {
        $k = $kvp.Key
        $v = $kvp.Value

        # Handle {{key:bool}} — converts non-empty to true, empty to false
        $boolVal = if ([string]::IsNullOrEmpty($v)) { "false" } else { "true" }
        $content = $content -replace [regex]::Escape("`"{{${k}:bool}}`""), $boolVal

        # Handle {{key}} for comma-separated list → JSON array (e.g. targetRGs)
        if ($k -eq "targetRGs" -and $v -match ",") {
            $items = $v -split "," | ForEach-Object { $_.Trim() }
            $jsonArray = "[" + (($items | ForEach-Object { "`"$_`"" }) -join ",") + "]"
            $content = $content -replace [regex]::Escape("`"{{${k}}}`""), " $jsonArray"
        }
        else {
            $content = $content -replace [regex]::Escape("{{${k}}}"), $v
        }
    }

    # Replace any remaining {{...:bool}} placeholders with false
    $content = $content -replace '"{{[^}]*:bool}}"', ' false'
    # Replace any remaining {{...}} placeholders with empty string
    $content = $content -replace '{{[^}]*}}', ''

    Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
}

# Handle targetRGs in agent.json — ensure it's a proper JSON array
if ($Values.ContainsKey("targetRGs") -and $Values["targetRGs"]) {
    $trgItems = $Values["targetRGs"] -split "," | ForEach-Object { $_.Trim() }
    $trgJson = ($trgItems | ForEach-Object { "`"$_`"" }) -join ","
    $trgJson = "[$trgJson]"
    $updated = jq --argjson rgs $trgJson '.identity.targetResourceGroups = $rgs' $outAgentJson
    $updated | Set-Content -Path $outAgentJson -Encoding UTF8
}

# Write secrets to connectors.secrets.env
$secretsEnv = Join-Path $Output "connectors.secrets.env"
$secretLines = @(
    "# SRE Agent connector secrets — DO NOT commit this file."
    "# Generated $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"
    ""
)

# Write any secret prompt values
foreach ($kvp in $Values.GetEnumerator()) {
    $k = $kvp.Key
    $v = $kvp.Value
    $isSecret = if ($Prompts.PSObject.Properties[$k] -and $Prompts.$k.PSObject.Properties['secret'] -and $Prompts.$k.secret -eq $true) { $true } else { $false }
    if ($isSecret -and -not [string]::IsNullOrEmpty($v)) {
        $envName = switch ($k) {
            "dtToken" { "DYNATRACE_BEARER_TOKEN" }
            default   { ($k -creplace '[a-z]', { $_.Value.ToUpper() }) -replace '[^A-Z0-9]', '_' }
        }
        $secretLines += "$envName=$v"
    }
}

$secretLines -join "`n" | Set-Content -Path $secretsEnv -Encoding UTF8 -NoNewline

# Create .gitignore if not present
$gitignorePath = Join-Path $Output ".gitignore"
if (-not (Test-Path $gitignorePath)) {
    @(
        "connectors.secrets.env"
        "*.secrets.env"
    ) -join "`n" | Set-Content -Path $gitignorePath -Encoding UTF8 -NoNewline
}

# Ensure data directories exist so users know where to place files
foreach ($subDir in @("data/knowledge", "data/synthesized-knowledge")) {
    $dirPath = Join-Path $Output $subDir
    if (-not (Test-Path $dirPath)) { $null = New-Item -ItemType Directory -Path $dirPath -Force }
    $gitkeep = Join-Path $dirPath ".gitkeep"
    if (-not (Test-Path $gitkeep)) { $null = New-Item -ItemType File -Path $gitkeep -Force }
}

# Fill subscription from current az context
try {
    $currentSub = az account show --query id -o tsv 2>$null
    if ($currentSub) {
        $updated = jq --arg s $currentSub '.identity.subscription = $s' $outAgentJson
        $updated | Set-Content -Path $outAgentJson -Encoding UTF8
    }
}
catch {}

Write-Host ""

# ─────────────────────────── Summary ───────────────────────────

Write-Host "── Setup complete ──" -ForegroundColor Green
Write-Host ""
Write-Host "  $Output/"
Write-Host "    agent.json               <- Review and adjust if needed"
Write-Host "    connectors.json          <- Connector configs"

$secretsContent = Get-Content $secretsEnv -Raw -ErrorAction SilentlyContinue
if ($secretsContent -and $secretsContent.Length -gt 0) {
    Write-Host "    connectors.secrets.env   <- Secrets (gitignored)"
}

Write-Host "    config/"
$configDirs = @("skills", "subagents", "tools", "hooks", "common-prompts", "plugin-configs", "repos")
foreach ($d in $configDirs) {
    $configPath = Join-Path $Output "config/$d"
    if (Test-Path $configPath -PathType Container) {
        $count = @(Get-ChildItem -Path "$configPath/*" -Include "*.json", "*.yaml" -File -ErrorAction SilentlyContinue).Count
        if ($count -gt 0) {
            Write-Host ("      {0,-24} <- {1} file(s)" -f "$d/", $count)
        }
    }
}

$automationsDir = Join-Path $Output "automations"
if (Test-Path $automationsDir -PathType Container) {
    $hasFiles = (Get-ChildItem -Path $automationsDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0
    if ($hasFiles) {
        Write-Host "    automations/"
        foreach ($d in @("scheduled-tasks", "incident-filters", "http-triggers", "incident-platforms")) {
            $autoPath = Join-Path $automationsDir $d
            if (Test-Path $autoPath -PathType Container) {
                $count = @(Get-ChildItem -Path "$autoPath/*" -Include "*.json", "*.yaml" -File -ErrorAction SilentlyContinue).Count
                if ($count -gt 0) {
                    Write-Host ("      {0,-24} <- {1} file(s)" -f "$d/", $count)
                }
            }
        }
    }
}

$dataDir = Join-Path $Output "data"
if (Test-Path $dataDir -PathType Container) {
    $dataFiles = @(Get-ChildItem -Path "$dataDir/*" -Include "*.md" -File -ErrorAction SilentlyContinue)
    if ($dataFiles.Count -gt 0) {
        Write-Host "    data/"
        Write-Host ("      {0,-24} <- {1} knowledge file(s)" -f "", $dataFiles.Count)
        foreach ($kf in $dataFiles) {
            Write-Host "        $($kf.Name)"
        }
    }
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Review $Output/agent.json"
Write-Host "  2. Dry run:"
Write-Host "       ./bin/deploy.sh $Output/ --dry-run"
Write-Host "  3. Deploy:"
Write-Host "       ./bin/deploy.sh $Output/"
Write-Host ""

# ── Telemetry ──
$region = if ($Values.ContainsKey("location")) { $Values["location"] } else { "unknown" }
Send-Telemetry -Action "new-agent" -Recipe $Recipe -Region $region
