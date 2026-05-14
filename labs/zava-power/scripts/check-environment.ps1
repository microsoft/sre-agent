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

# ── 4. RBAC tier probe (T1 → T2 → T3 with user prompt on fallback) ──
# Determines what permission tier the SRE Agent's MI will get:
#   T1 (custom)      = least-privilege "PowerGrid SRE Agent Operator" custom role
#   T2 (contributor) = built-in Contributor scoped to the RG
#   T3 (readonly)    = no operator role; agent detects/diagnoses but every action
#                      is routed through the agent's approval flow for a human admin
# User can override by setting RBAC_TIER explicitly: `azd env set RBAC_TIER contributor`
Write-Host "═══ RBAC tier probe ═══" -ForegroundColor Cyan

$rbacTier = Get-AzdEnv 'RBAC_TIER'
$operatorRoleId = ''
$noPrompt = $env:AZD_NON_INTERACTIVE -eq 'true' -or $args -contains '--no-prompt'

if ($rbacTier) {
    Write-Host "  RBAC_TIER explicitly set to '$rbacTier' — skipping probe" -ForegroundColor DarkGray
    # Resolve role id for explicitly-set tiers
    if ($rbacTier -eq 'contributor') {
        $operatorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    }
    elseif ($rbacTier -eq 'custom') {
        $existing = az role definition list --custom-role-only true --name 'PowerGrid SRE Agent Operator' 2>$null | ConvertFrom-Json
        if ($existing) { $operatorRoleId = $existing[0].name }
        else { Write-Host "  ⚠ RBAC_TIER=custom but role not found — bicep will fail. Run probe (unset RBAC_TIER) or create role first." -ForegroundColor Yellow }
    }
}
else {
    $subId = $acct.id
    $rgName = (Get-AzdEnv 'AZURE_RESOURCE_GROUP'); if (-not $rgName) { $rgName = 'rg-powergrid' }

    # ── T1: try to create the custom role (idempotent — "already exists" is success) ──
    Write-Host "  Probing T1 (custom least-priv role 'PowerGrid SRE Agent Operator')..." -NoNewline
    $roleJsonSrc = Join-Path $PSScriptRoot '..\infra\roles\powergrid-sre-agent-operator.json'
    $roleJsonTmp = Join-Path ([System.IO.Path]::GetTempPath()) "powergrid-role-$([Guid]::NewGuid().ToString('N')).json"
    (Get-Content $roleJsonSrc -Raw) `
        -replace '<SUBSCRIPTION_ID>', $subId `
        -replace '<RESOURCE_GROUP>', $rgName `
        | Set-Content $roleJsonTmp -Encoding utf8

    $existing = az role definition list --custom-role-only true --name 'PowerGrid SRE Agent Operator' 2>$null | ConvertFrom-Json
    if ($existing -and $existing.Count -gt 0) {
        $operatorRoleId = $existing[0].name
        $rbacTier = 'custom'
        Write-Host " ✓ exists (id=$operatorRoleId)" -ForegroundColor Green
    } else {
        $createOut = az role definition create --role-definition $roleJsonTmp 2>&1
        if ($LASTEXITCODE -eq 0) {
            $created = $createOut | ConvertFrom-Json
            $operatorRoleId = $created.name
            $rbacTier = 'custom'
            Write-Host " ✓ created (id=$operatorRoleId)" -ForegroundColor Green
            Start-Sleep -Seconds 30  # propagation
        } else {
            $reason = if ($createOut -match 'RoleDefinitionLimitExceeded') { 'tenant custom-role limit exceeded' }
                      elseif ($createOut -match 'AuthorizationFailed') { 'caller lacks Microsoft.Authorization/roleDefinitions/write' }
                      else { ($createOut | Out-String).Trim() -replace '\s+', ' ' }
            Write-Host " ✗ unavailable: $reason" -ForegroundColor Yellow

            # ── Prompt unless --no-prompt ──
            if ($noPrompt) {
                Write-Host "  Non-interactive mode — defaulting to T3 (readonly)" -ForegroundColor Yellow
                $rbacTier = 'readonly'
            } else {
                Write-Host ""
                Write-Host "  T1 (custom least-priv) is unavailable. Choose fallback:" -ForegroundColor Cyan
                Write-Host "    [1] T2 — Built-in Contributor scoped to $rgName"
                Write-Host "          Agent gets full remediation; broader perms than T1."
                Write-Host "    [2] T3 — Read-only (no operator role)"
                Write-Host "          Agent detects/diagnoses; remediation goes to human admin via approval flow."
                Write-Host "    [3] Abort"
                $choice = Read-Host "  Choice [1/2/3]"
                switch ($choice) {
                    '1' {
                        $rbacTier = 'contributor'
                        # Built-in Contributor role definition GUID
                        $operatorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
                    }
                    '2' { $rbacTier = 'readonly' }
                    default { Write-Host "Aborted by user." -ForegroundColor Red; exit 1 }
                }
            }
        }
    }
    Remove-Item $roleJsonTmp -ErrorAction SilentlyContinue
}

azd env set RBAC_TIER $rbacTier | Out-Null
azd env set AGENT_OPERATOR_ROLE_ID $operatorRoleId | Out-Null

$tierLabel = switch ($rbacTier) {
    'custom'      { 'T1 (custom least-priv) — agent has full remediation via PowerGrid SRE Agent Operator' }
    'contributor' { 'T2 (built-in Contributor) — agent has full remediation; broader perms than T1' }
    'readonly'    { 'T3 (read-only) — agent detects/diagnoses; remediation routed to human admin' }
}
Write-Host "  RBAC tier: $tierLabel`n" -ForegroundColor Green
