#requires -Version 7.0
<#
preprovision hook — runs BEFORE bicep deploy.
  1. Verify prerequisites
  2. Prompt for ServiceNow PDI credentials (only thing azd can't infer)
  3. Stash secrets in azd env so postprovision + sim can read them
#>
$ErrorActionPreference = 'Stop'

# ── 1. Prerequisites ──
$missing = @()
function Test-Tool($n, $hint) {
    if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
        Write-Host "  ✗ $n not found — $hint" -ForegroundColor Red
        $script:missing += $n
    } else { Write-Host "  ✓ $n" -ForegroundColor Green }
}
Write-Host "═══ PowerGrid ZeroOps prereqs ═══" -ForegroundColor Cyan
Test-Tool az      "https://aka.ms/azcli"
Test-Tool azd     "https://aka.ms/azd-install"
Test-Tool python  "https://www.python.org/downloads/  (3.11+)"
Test-Tool docker  "https://docs.docker.com/get-docker/"
Test-Tool srectl  "https://aka.ms/srectl-install  (required for SRE Agent config)"
if ($missing.Count -gt 0) { Write-Host "`nInstall missing tools and retry." -ForegroundColor Yellow; exit 1 }

$acct = az account show 2>$null | ConvertFrom-Json
if (-not $acct) { Write-Host "`nRun 'az login' first." -ForegroundColor Yellow; exit 1 }
Write-Host "  Subscription: $($acct.name) ($($acct.id))" -ForegroundColor DarkGray

# ── 2. ServiceNow PDI prompts (only if not already in azd env) ──
$envValues = (azd env get-values --output json 2>$null | ConvertFrom-Json)
function Get-AzdEnv($name) { if ($envValues -and $envValues.PSObject.Properties[$name]) { $envValues.$name } else { $null } }

if (-not (Get-AzdEnv 'SERVICENOW_INSTANCE')) {
    Write-Host "`n═══ ServiceNow PDI setup ═══" -ForegroundColor Cyan
    Write-Host "Need a free ServiceNow PDI: https://developer.servicenow.com/dev.do (sign in → Request Instance)" -ForegroundColor DarkGray
    $sn = Read-Host "ServiceNow instance hostname (e.g. dev123456)"
    $snUser = Read-Host "ServiceNow admin username [admin]"
    if (-not $snUser) { $snUser = 'admin' }
    $snPass = Read-Host "ServiceNow admin password" -AsSecureString
    $snPassPlain = [System.Net.NetworkCredential]::new('', $snPass).Password
    azd env set SERVICENOW_INSTANCE $sn | Out-Null
    azd env set SERVICENOW_USER     $snUser | Out-Null
    azd env set SERVICENOW_PASSWORD $snPassPlain | Out-Null
    Write-Host "  ✓ stashed in azd env" -ForegroundColor Green
} else {
    Write-Host "`n  ✓ ServiceNow creds already in azd env (re-running)" -ForegroundColor DarkGray
}

# ── 3. Workload defaults ──
foreach ($k in @{
    WORKLOAD_NAME        = 'powergrid'
    CONTAINER_APP_PREFIX = 'ca-powergrid'
    SRE_OPS_AGENT_NAME       = 'sre-zavapower-ops'
    DEMO_EMPLOYEE_EMAIL  = 'demo.user@zavapower.com'
    ADO_ORG              = 'placeholder-ado-org'
    ADO_REPO             = 'placeholder-ado-repo'
    GH_TEMPLATE_ORG      = 'microsoft'
    GH_USER              = 'demo-user'
}.GetEnumerator()) {
    if (-not (Get-AzdEnv $k.Key)) { azd env set $k.Key $k.Value | Out-Null }
}

Write-Host "`n  Ready to deploy. azd will provision Azure resources next.`n" -ForegroundColor Green
