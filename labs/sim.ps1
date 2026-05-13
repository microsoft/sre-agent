#requires -Version 7.0
<#
.SYNOPSIS
  Zava Unlimited meta-simulator. One picker for all your deployed labs.

.EXAMPLE
  ./sim.ps1                                     # interactive
  ./sim.ps1 -Lab zava-power                     # open that lab's own sim
  ./sim.ps1 -Scenario zava-power/api-perf-regression   # run one scenario directly
  ./sim.ps1 -List                               # list deployed labs + scenarios
#>
[CmdletBinding()]
param(
    [string]$Lab,
    [string]$Scenario,
    [switch]$List
)
$ErrorActionPreference = 'Stop'
$labsRoot = $PSScriptRoot
$helper = Join-Path $labsRoot '_platform/helpers/manifest.py'

function Read-Manifest($name) {
    $dir = Join-Path $labsRoot $name
    if (-not (Test-Path (Join-Path $dir 'lab.yaml'))) { return $null }
    return (& python $helper read $dir | ConvertFrom-Json)
}

function Get-Deployed {
    $raw = & python $helper deployed $labsRoot | ConvertFrom-Json
    if ($null -eq $raw) { return @() }
    if ($raw -isnot [array]) { return @($raw) }
    return $raw
}

function Show-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   Zava Unlimited — SRE Agent Simulator   ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Invoke-LabSim($manifest) {
    $labDir = Join-Path $labsRoot $manifest.name
    $sim = $manifest.sim
    if (-not $sim) { Write-Host "  ✗ '$($manifest.name)' has no sim entry in lab.yaml" -ForegroundColor Red; return }
    Write-Host "`n  ▶ Launching $($manifest.displayName) sim ..." -ForegroundColor Green
    Push-Location $labDir
    try { & $sim.command @($sim.args) } finally { Pop-Location }
}

function Invoke-Scenario($manifest, $scenario) {
    $labDir = Join-Path $labsRoot $manifest.name
    if (-not $scenario.runner) {
        Write-Host "`n  ▶ $($manifest.displayName) :: $($scenario.label)" -ForegroundColor Green
        Write-Host "    (No standalone runner. Scenarios in this lab run inside the main sim — launching it.)" -ForegroundColor DarkGray
        Invoke-LabSim $manifest
        return
    }
    $runner = Join-Path $labDir $scenario.runner
    if (-not (Test-Path $runner)) {
        Write-Host "  ✗ runner not found: $($scenario.runner)" -ForegroundColor Red
        Write-Host "    (Lab '$($manifest.name)' declares this scenario but the file is missing.)" -ForegroundColor DarkGray
        return
    }
    Write-Host "`n  ▶ $($manifest.displayName) :: $($scenario.label)" -ForegroundColor Green
    Push-Location $labDir
    try {
        if ($runner -match '\.ps1$')  { & pwsh -NoProfile -File $runner }
        elseif ($runner -match '\.py$') { & python $runner }
        elseif ($runner -match '\.sh$') { & bash $runner }
        else { & $runner }
    } finally { Pop-Location }
}

# ── Discover what's deployed and what those labs declare ──
$deployed = Get-Deployed
if ($deployed.Count -eq 0) {
    Show-Banner
    Write-Host "`n  No deployed labs found.`n" -ForegroundColor Yellow
    Write-Host "  Deploy one first:  ./lab.ps1`n" -ForegroundColor DarkGray
    exit 0
}

$catalog = @()
foreach ($d in $deployed) {
    $m = Read-Manifest $d.name
    if ($null -eq $m) { continue }
    $catalog += [PSCustomObject]@{
        Name = $d.name; DisplayName = $m.displayName; Description = $m.description
        Subsidiary = $m.subsidiary; Manifest = $m; Deployment = $d
        Scenarios = @($m.scenarios)
    }
}

# ── -List ──
if ($List) {
    Show-Banner
    Write-Host "`n  Deployed labs:`n" -ForegroundColor Cyan
    foreach ($c in $catalog) {
        Write-Host ("    {0,-24} {1}" -f $c.Name, $c.DisplayName)
        Write-Host ("    {0,-24} rg={1}  agent={2}" -f '', $c.Deployment.resourceGroup, $c.Deployment.sreAgentName) -ForegroundColor DarkGray
        foreach ($s in $c.Scenarios) {
            Write-Host ("        • {0,-28} ({1} min) {2}" -f $s.id, $s.minutes, $s.description) -ForegroundColor DarkGray
        }
    }
    Write-Host ""; exit 0
}

# ── -Scenario lab/id ──
if ($Scenario) {
    if ($Scenario -notmatch '^(?<lab>[^/]+)/(?<id>.+)$') { Write-Host "  ✗ -Scenario must be 'lab/id' (e.g. zava-power/api-perf-regression)" -ForegroundColor Red; exit 1 }
    $c = $catalog | Where-Object Name -eq $matches.lab | Select-Object -First 1
    if (-not $c) { Write-Host "  ✗ lab '$($matches.lab)' not deployed. Use -List." -ForegroundColor Red; exit 1 }
    $s = $c.Scenarios | Where-Object id -eq $matches.id | Select-Object -First 1
    if (-not $s) { Write-Host "  ✗ scenario '$($matches.id)' not in $($c.Name)" -ForegroundColor Red; exit 1 }
    Invoke-Scenario $c.Manifest $s; exit $LASTEXITCODE
}

# ── -Lab name ──
if ($Lab) {
    $c = $catalog | Where-Object Name -eq $Lab | Select-Object -First 1
    if (-not $c) { Write-Host "  ✗ lab '$Lab' not deployed. Use -List." -ForegroundColor Red; exit 1 }
    Invoke-LabSim $c.Manifest; exit $LASTEXITCODE
}

# ── Interactive picker ──
Show-Banner
Write-Host "`n  Deployed labs:`n" -ForegroundColor Cyan
for ($i = 0; $i -lt $catalog.Count; $i++) {
    $c = $catalog[$i]
    $tag = if ($c.Subsidiary) { "[$($c.Subsidiary)]" } else { '' }
    Write-Host ("    [{0}] {1,-24} {2,-22} {3} scenarios" -f ($i+1), $c.Name, $tag, $c.Scenarios.Count)
}
Write-Host "`n    [u] unified scenario picker (across all deployed labs)"
Write-Host "    [q] quit`n"
$pick = Read-Host "  Pick"
if ($pick -in 'q','quit') { exit 0 }

if ($pick -in 'u','unified') {
    $allScn = @()
    foreach ($c in $catalog) {
        foreach ($s in $c.Scenarios) {
            $allScn += [PSCustomObject]@{ Lab = $c; Scenario = $s }
        }
    }
    if ($allScn.Count -eq 0) { Write-Host "`n  No scenarios declared in any deployed lab.`n" -ForegroundColor Yellow; exit 0 }
    Write-Host "`n  All scenarios:`n" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allScn.Count; $i++) {
        $row = $allScn[$i]
        Write-Host ("    [{0,2}] {1,-24} {2,-30} ({3} min)" -f ($i+1), $row.Lab.Name, $row.Scenario.label, $row.Scenario.minutes)
    }
    Write-Host ""
    $p2 = Read-Host "  Pick scenario number"
    if ($p2 -match '^\d+$' -and [int]$p2 -ge 1 -and [int]$p2 -le $allScn.Count) {
        $row = $allScn[[int]$p2 - 1]
        Invoke-Scenario $row.Lab.Manifest $row.Scenario
    } else { Write-Host "  invalid pick"; exit 1 }
    exit 0
}

if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $catalog.Count) {
    Invoke-LabSim $catalog[[int]$pick - 1].Manifest
    exit $LASTEXITCODE
}
Write-Host "  invalid pick"; exit 1
