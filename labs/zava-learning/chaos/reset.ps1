<#
.SYNOPSIS
  Master restore for the Zava Learning lab. Returns selected chaos lanes to baseline.

.DESCRIPTION
  Calls the same fix logic used by each lane's fix-*.ps1 script, then resolves open
  PagerDuty incidents so the next lab run starts clean. The -Redeploy switch is kept
  for compatibility with older demos; lane reset now uses targeted live reconciliation.
#>
param(
  [ValidateSet('nsg','appgw','app','perf','query','pool','secret','disk','all')][string]$Scenario = 'all',
  [bool]$Redeploy = $true,
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

$targets = if ($Scenario -eq 'all') { @('nsg','appgw','app','perf','query','pool','secret','disk') } else { @($Scenario) }
Write-Host "[reset] Restoring scenario(s): $($targets -join ', ')  (Redeploy=$Redeploy; targeted lane fixes)" -ForegroundColor Yellow

foreach ($target in $targets) {
  $script = Join-Path $PSScriptRoot "fix-$target.ps1"
  if (-not (Test-Path $script)) { throw "Fix script not found: $script" }
  Write-Host "  Running fix-$target.ps1..." -ForegroundColor Gray
  & $script -ResourceGroup $ResourceGroup
}

Write-Host "  Resolving any open PagerDuty incidents (clean slate)..." -ForegroundColor Gray
Resolve-OpenPagerDutyIncidents

Write-Host "[reset] Done. Source and live state restored to baseline." -ForegroundColor Green
