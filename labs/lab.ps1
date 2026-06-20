#requires -Version 7.0
<#
.SYNOPSIS
  Top-level lab launcher. Auto-discovers any subdirectory with an azure.yaml
  and lets you pick one (or several) to deploy.

.EXAMPLE
  ./lab.ps1                                 # interactive picker
  ./lab.ps1 -Labs powergrid-zeroops         # deploy one lab non-interactively
  ./lab.ps1 -Labs powergrid-zeroops,itops   # deploy multiple, no auto-launch
  ./lab.ps1 -List                           # just list available labs
  ./lab.ps1 -Down powergrid-zeroops         # tear down a lab
#>
[CmdletBinding()]
param(
    [string[]]$Labs,
    [string]  $Down,
    [string]  $New,
    [switch]  $List,
    [switch]  $NoLaunch
)
$ErrorActionPreference = 'Stop'

# ── -New: scaffold a new lab from the template ──
if ($New) {
    if ($New -notmatch '^[a-z][a-z0-9-]+$') {
        Write-Host "  ✗ lab name must be kebab-case (e.g. zava-fintech, my-lab)" -ForegroundColor Red; exit 1
    }
    $target = Join-Path $PSScriptRoot $New
    if (Test-Path $target) { Write-Host "  ✗ '$New' already exists at $target" -ForegroundColor Red; exit 1 }

    Write-Host "`n═══ New lab: $New ═══`n" -ForegroundColor Cyan
    $displayName = Read-Host "  Display name (e.g. 'Zava Fintech — Trading Platform')"
    if (-not $displayName) { $displayName = $New }
    $subsidiary = Read-Host "  Zava subsidiary (e.g. 'Zava Fintech') [optional]"
    $description = Read-Host "  One-sentence description"
    if (-not $description) { $description = "TODO: describe what this lab demonstrates." }
    $tagsCsv = Read-Host "  Tags (comma-separated, e.g. aks,postgres,autoremediation) [optional]"
    $tags = if ($tagsCsv) { ($tagsCsv -split '[, ]+' | Where-Object { $_ } | ForEach-Object { "'$_'" }) -join ', ' } else { '' }

    $tplRoot = Join-Path $PSScriptRoot '_platform/template'
    $sub = @{
        '{{LAB_NAME}}'         = $New
        '{{LAB_DISPLAY_NAME}}' = $displayName
        '{{LAB_SUBSIDIARY}}'   = $subsidiary
        '{{LAB_DESCRIPTION}}'  = $description
        '{{LAB_TAGS}}'         = $tags
    }
    function Apply-Substitutions([string]$text) {
        foreach ($k in $sub.Keys) { $text = $text.Replace($k, $sub[$k]) }
        return $text
    }

    # Copy + substitute
    $count = 0
    Get-ChildItem $tplRoot -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($tplRoot.Length).TrimStart('\','/')
        # Strip .tmpl extension
        if ($rel -like '*.tmpl') { $rel = $rel.Substring(0, $rel.Length - 5) }
        $dest = Join-Path $target $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $body = Apply-Substitutions (Get-Content $_.FullName -Raw -Encoding utf8)
        Set-Content $dest $body -Encoding utf8
        $count++
    }

    Write-Host "`n  ✓ scaffolded $count files at $target" -ForegroundColor Green
    Write-Host "`n  Next steps:" -ForegroundColor Cyan
    Write-Host "    1. Edit $New/lab.yaml — add prereqs, prompts, scenarios"
    Write-Host "    2. Edit $New/infra/main.bicep — add your Azure resources"
    Write-Host "    3. Add scenario runners under $New/scripts/scenarios/"
    Write-Host "    4. Validate:  python _platform/helpers/manifest.py validate $New/lab.yaml"
    Write-Host "    5. Deploy:    ./lab.sh -Labs $New`n"
    exit 0
}

# ── Discover labs (any sibling dir with lab.yaml or azure.yaml) ──
$helper = Join-Path $PSScriptRoot '_platform/helpers/manifest.py'
$useManifest = (Test-Path $helper) -and (Get-Command python -ErrorAction SilentlyContinue)

if ($useManifest) {
    try {
        $rawJson = (& python $helper list $PSScriptRoot) -join "`n"
        $available = ($rawJson | ConvertFrom-Json) | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.name; Path = $_._path
                Description = $_.description
                Manifest = $_
                IsLegacy = [bool]$_._legacy
            }
        }
    } catch {
        $useManifest = $false
        Write-Host "  ⚠ manifest helper failed ($_), falling back to azure.yaml discovery" -ForegroundColor DarkYellow
    }
}

if (-not $useManifest) {
    $available = Get-ChildItem $PSScriptRoot -Directory |
        Where-Object { (Test-Path (Join-Path $_.FullName 'azure.yaml')) -and -not $_.Name.StartsWith('_') } |
        ForEach-Object {
            $readme = Join-Path $_.FullName 'README.md'
            $desc = if (Test-Path $readme) {
                (Get-Content $readme -TotalCount 4 | Where-Object { $_ -and $_ -notmatch '^#' } | Select-Object -First 1)
            } else { '(no description)' }
            [PSCustomObject]@{ Name = $_.Name; Path = $_.FullName; Description = $desc; Manifest = $null; IsLegacy = $true }
        }
}

if ($available.Count -eq 0) {
    Write-Host "`nNo labs found under $PSScriptRoot (need a child dir with azure.yaml).`n" -ForegroundColor Yellow
    exit 1
}

# ── -List ──
if ($List) {
    Write-Host "`nAvailable labs:" -ForegroundColor Cyan
    $available | ForEach-Object { Write-Host ("  • {0,-30} {1}" -f $_.Name, $_.Description) }
    Write-Host ""; exit 0
}

# ── -Down ──
if ($Down) {
    $target = $available | Where-Object Name -eq $Down
    if (-not $target) { Write-Host "Unknown lab '$Down'. Use -List to see options." -ForegroundColor Red; exit 1 }
    Push-Location $target.Path
    try { azd down --purge --force } finally { Pop-Location }
    exit 0
}

# ── Resolve / prompt for selection ──
if (-not $Labs) {
    Write-Host "`n═══ SRE Agent labs ═══" -ForegroundColor Cyan
    Write-Host "Which lab(s) do you want to deploy?`n"
    for ($i = 0; $i -lt $available.Count; $i++) {
        Write-Host ("  [{0}] {1,-30} {2}" -f ($i+1), $available[$i].Name, $available[$i].Description)
    }
    Write-Host ("  [a] all ({0} labs)" -f $available.Count)
    Write-Host "  [q] quit`n"
    $pick = Read-Host "Pick (number, comma-separated for multiple, 'a' for all)"
    if ($pick -eq 'q') { exit 0 }
    if ($pick -eq 'a' -or $pick -eq 'all') {
        $Labs = $available.Name
    } else {
        $idxs = $pick -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ - 1 }
        $Labs = @($idxs | Where-Object { $_ -ge 0 -and $_ -lt $available.Count } | ForEach-Object { $available[$_].Name })
        if ($Labs.Count -eq 0) { Write-Host "No valid selection." -ForegroundColor Red; exit 1 }
    }
}

# ── Validate selections ──
$bad = $Labs | Where-Object { $_ -notin $available.Name }
if ($bad) { Write-Host "Unknown lab(s): $($bad -join ', '). Use -List." -ForegroundColor Red; exit 1 }

# ── Multi-pick: skip in-postprovision sim auto-launch (interleaving sims is bad UX) ──
if ($Labs.Count -gt 1 -or $NoLaunch) {
    $env:LAB_NO_AUTOLAUNCH = '1'
    Write-Host "`n  Multi-lab deploy: simulator auto-launch suppressed. Run it manually after.`n" -ForegroundColor DarkGray
}

# ── Deploy each pick sequentially ──
$results = @()
foreach ($lab in $Labs) {
    $target = $available | Where-Object Name -eq $lab | Select-Object -First 1
    Write-Host "`n┌─────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host   "│ Deploying $lab" -ForegroundColor Cyan
    Write-Host   "└─────────────────────────────────────────────`n" -ForegroundColor Cyan

    # If the lab declares prompts in its manifest, collect them upfront and stash in azd env.
    # (azd hooks can also prompt — this is for labs whose preprovision hook reads from azd env.)
    if (-not $target.IsLegacy -and $target.Manifest.prompts) {
        Push-Location $target.Path
        try {
            $existing = (azd env get-values --output json 2>$null | ConvertFrom-Json)
            foreach ($p in $target.Manifest.prompts) {
                $present = $existing -and $existing.PSObject.Properties[$p.name]
                if ($present) { continue }
                $promptText = "  $($p.text)"
                if ($p.default) { $promptText += " [$($p.default)]" }
                if ($p.secret) {
                    $val = Read-Host -AsSecureString $promptText
                    $val = [System.Net.NetworkCredential]::new('', $val).Password
                } else {
                    $val = Read-Host $promptText
                }
                if (-not $val -and $p.default) { $val = $p.default }
                if (-not $val -and -not $p.optional) { Write-Host "    (skipped $($p.name))" -ForegroundColor DarkYellow; continue }
                if ($val) { azd env set $p.name $val | Out-Null }
            }
        } finally { Pop-Location }
    }

    Push-Location $target.Path
    try {
        # Unified prereq gate — fails fast if azd/az/srectl/login missing
        & (Join-Path $PSScriptRoot '_platform/check-prereqs.ps1') -Lab $lab
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ✗ prereq check failed for $lab — skipping" -ForegroundColor Red
            $results += [PSCustomObject]@{ Lab = $lab; OK = $false; Path = $target.Path }
            Pop-Location
            continue
        }
        azd up
        $ok = $LASTEXITCODE -eq 0
        $results += [PSCustomObject]@{ Lab = $lab; OK = $ok; Path = $target.Path }
    } finally { Pop-Location }
}

# ── Summary ──
Write-Host "`n═══ Summary ═══" -ForegroundColor Cyan
foreach ($r in $results) {
    $mark = if ($r.OK) { '✓' } else { '✗' }
    $color = if ($r.OK) { 'Green' } else { 'Red' }
    Write-Host ("  {0} {1}" -f $mark, $r.Lab) -ForegroundColor $color
}
if ($Labs.Count -gt 1) {
    Write-Host "`nTo run any lab's simulator:" -ForegroundColor DarkGray
    foreach ($r in $results | Where-Object OK) {
        Write-Host "  cd $($r.Lab) && python simulator/demo.py" -ForegroundColor DarkGray
    }
}
Write-Host ""
