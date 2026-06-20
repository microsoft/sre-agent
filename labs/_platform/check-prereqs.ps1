<#
.SYNOPSIS
  Unified prereq gate for every lab. Run BEFORE `azd up` so users don't burn
  20-30 minutes provisioning Azure resources only to fail at post-provision.

.PARAMETER Lab
  The lab name (only used in the printed banner).

.PARAMETER Strict
  If set, any missing/private prereq aborts. Default: warn but allow continue.

.NOTES
  srectl + the SRE Agent MCP server are currently in *Microsoft private preview*.
  Public users cannot pull them from the web. The honest UX:
    1. Detect them.
    2. If missing, point at the onboarding contact + offer a "infra-only" mode
       (Bicep deploys, but skip the post-provision srectl steps).
#>
[CmdletBinding()]
param(
    [string]$Lab = "(unknown)",
    [switch]$Strict
)

$ErrorActionPreference = 'Continue'
$missing = @()
$private = @()

function Test-Cmd {
    param([string]$Name, [string]$Hint, [switch]$Private)
    if (Get-Command $Name -ErrorAction SilentlyContinue) {
        Write-Host "  ✓ $Name" -ForegroundColor Green
        return $true
    }
    if ($Private) {
        Write-Host "  ⚠ $Name (Microsoft private preview — $Hint)" -ForegroundColor Yellow
        $script:private += $Name
    } else {
        Write-Host "  ✗ $Name (install: $Hint)" -ForegroundColor Red
        $script:missing += $Name
    }
    return $false
}

Write-Host "`n═══ Prereq check for '$Lab' ═══`n" -ForegroundColor Cyan

# --- public, required for every lab ---
Test-Cmd 'azd'    'https://aka.ms/azd-install' | Out-Null
Test-Cmd 'az'     'https://aka.ms/install-azure-cli' | Out-Null
Test-Cmd 'python' 'https://www.python.org/downloads/' | Out-Null
Test-Cmd 'pwsh'   'https://aka.ms/powershell' | Out-Null

# --- private preview ---
$srectlPresent = Test-Cmd 'srectl' 'request access via aka.ms/sreagent-onboarding' -Private

# --- az login state ---
$acct = az account show 2>$null | ConvertFrom-Json
if ($acct) {
    Write-Host "  ✓ az login: $($acct.user.name) ($($acct.name))" -ForegroundColor Green
} else {
    Write-Host "  ✗ not logged in to Azure — run: az login" -ForegroundColor Red
    $missing += 'az login'
}

# --- azd login state (best-effort) ---
$azdAuth = azd auth login --check-status 2>&1 | Out-String
if ($azdAuth -match 'Logged in') {
    Write-Host "  ✓ azd login" -ForegroundColor Green
} else {
    Write-Host "  ⚠ azd not logged in — run: azd auth login" -ForegroundColor Yellow
}

# --- summary ---
Write-Host ""
if ($missing.Count -gt 0) {
    Write-Host "✗ Missing required tools: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "  Install them and re-run. Aborting.`n" -ForegroundColor Red
    exit 2
}

if ($private.Count -gt 0) {
    Write-Host "⚠ Private-preview tools missing: $($private -join ', ')" -ForegroundColor Yellow
    Write-Host @"

  These tools are required for the SRE Agent configuration step that runs
  AFTER the Bicep infrastructure deploy:

    • srectl — applies subagents/skills/tools/scheduled-tasks to the agent
    • SRE Agent MCP — optional; surfaces srectl as MCP tools to your IDE

  If you don't have access yet, the lab's Bicep stage will still deploy the
  Azure infrastructure successfully, but post-provision will fail when it
  tries to call ``srectl init`` / ``srectl apply-yaml``.

  To get access:
    1. Microsoft FTEs: see https://aka.ms/sreagent-onboarding (internal)
    2. Customers: contact your Microsoft account team for SRE Agent preview

"@ -ForegroundColor DarkYellow

    if ($Strict) {
        Write-Host "  -Strict set — aborting.`n" -ForegroundColor Red
        exit 3
    }

    $env:LABS_SKIP_SRECTL = '1'
    $resp = Read-Host "  Continue with infra-only deploy (skip srectl steps)? [y/N]"
    if ($resp -notmatch '^[yY]') {
        Write-Host "  Aborted by user.`n" -ForegroundColor Yellow
        exit 4
    }
    Write-Host "  → LABS_SKIP_SRECTL=1 set; post-provision scripts should honour this.`n" -ForegroundColor Yellow
} else {
    Write-Host "✓ All prereqs present.`n" -ForegroundColor Green
}

exit 0
