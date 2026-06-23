<#
.SYNOPSIS
  Idempotently configures PagerDuty incident priority on the PD side (not via the SRE Agent).

.DESCRIPTION
  Two paths create PagerDuty incidents in this lab:
    1. Demo / break scripts -> REST POST /incidents (chaos/_common.ps1 sets priority at creation,
       default P2 via PAGERDUTY_DEFAULT_PRIORITY).
    2. Azure Monitor alerts -> action group webhook -> PagerDuty Events API v2 (/enqueue).
       Events-API incidents carry a `severity`, not a priority, so without an Event Orchestration
       rule they land UNPRIORITIZED.

  This script installs a Service Event Orchestration on the PD service so AzMon-originated
  incidents get a priority on the PD side:
        critical -> P1, warning -> P3, everything else -> P2.

  Re-running replaces the orchestration path with the same content (idempotent).

.NOTES
  Reads PAGERDUTY_API_TOKEN / PAGERDUTY_SERVICE_ID / PAGERDUTY_FROM_EMAIL from sre-config/.env
  (or the environment). Priority IDs are resolved by name via GET /priorities (never hardcoded).
#>
[CmdletBinding()]
param(
  [string]$CriticalPriority = 'P1',
  [string]$WarningPriority  = 'P3',
  [string]$DefaultPriority  = 'P2'
)

$ErrorActionPreference = 'Stop'

# --- load config from sre-config/.env (fallback to environment) ---
$repoRoot = Split-Path -Parent $PSScriptRoot
$envFile  = Join-Path $repoRoot 'sre-config\.env'
$cfg = @{}
if (Test-Path $envFile) {
  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.+)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
  }
}
function Get-Cfg([string]$name) {
  $envVal = [Environment]::GetEnvironmentVariable($name)
  if ($envVal) { return $envVal }
  if ($cfg.ContainsKey($name)) { return $cfg[$name] }
  return $null
}

$token   = Get-Cfg 'PAGERDUTY_API_TOKEN'
$service = Get-Cfg 'PAGERDUTY_SERVICE_ID'
if (-not $token)   { throw 'PAGERDUTY_API_TOKEN not found in sre-config/.env or environment.' }
if (-not $service) { throw 'PAGERDUTY_SERVICE_ID not found in sre-config/.env or environment.' }
$from = Get-Cfg 'PAGERDUTY_FROM_EMAIL'
if (-not $from) {
  try {
    $u = Invoke-RestMethod -Uri 'https://api.pagerduty.com/users?limit=1' -Headers @{ Authorization = "Token token=$token"; Accept = 'application/vnd.pagerduty+json;version=2' }
    $from = $u.users[0].email
  } catch {}
}
if (-not $from) { throw 'Set PAGERDUTY_FROM_EMAIL (a valid PagerDuty user email) in sre-config/.env or environment.' }

$headers = @{
  Authorization  = "Token token=$token"
  Accept         = 'application/vnd.pagerduty+json;version=2'
  'Content-Type' = 'application/json'
  From           = $from
}

# --- resolve priority names -> ids ---
$priorities = (Invoke-RestMethod -Uri 'https://api.pagerduty.com/priorities' -Headers $headers).priorities
function Resolve-Priority([string]$name) {
  $p = $priorities | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if (-not $p) { throw "Priority '$name' not found on this PagerDuty account." }
  return $p.id
}
$p1 = Resolve-Priority $CriticalPriority
$p3 = Resolve-Priority $WarningPriority
$p2 = Resolve-Priority $DefaultPriority

# --- install the Service Event Orchestration (idempotent PUT) ---
$body = @{
  orchestration_path = @{
    sets = @(@{
      id    = 'start'
      rules = @(
        @{ label = "AzMon critical -> $CriticalPriority"; conditions = @(@{ expression = "event.severity matches 'critical'" }); actions = @{ priority = $p1 } },
        @{ label = "AzMon warning -> $WarningPriority";   conditions = @(@{ expression = "event.severity matches 'warning'" });  actions = @{ priority = $p3 } }
      )
    })
    catch_all = @{ actions = @{ priority = $p2 } }
  }
} | ConvertTo-Json -Depth 8

$result = Invoke-RestMethod -Method Put -Uri "https://api.pagerduty.com/event_orchestrations/services/$service" -Headers $headers -Body $body

Write-Host "PagerDuty priority orchestration applied to service ${service}:" -ForegroundColor Green
foreach ($r in $result.orchestration_path.sets.rules) {
  Write-Host ("  - {0} => priority {1}" -f $r.label, $r.actions.priority)
}
Write-Host ("  - catch-all => priority {0} ({1})" -f $result.orchestration_path.catch_all.actions.priority, $DefaultPriority)
