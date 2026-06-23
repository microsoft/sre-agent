<#
.SYNOPSIS
  Pool lane role-state drift: caps app_pool to one connection live.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[break-pool] Tightening the app_pool connection limit in PostgreSQL..." -ForegroundColor Yellow
# Clamp the role to a single connection AND drop its existing sessions, so the lane's pool must
# reconnect under the new limit (otherwise an already-established connection lingers and the fault
# would only appear once idle connections time out).
Invoke-PgSql -ResourceGroup $ResourceGroup -Database "zava" `
  -Sql "ALTER ROLE app_pool CONNECTION LIMIT 1; SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'app_pool' AND pid <> pg_backend_pid();"

Write-Host "[break-pool] Live role drift applied. The pool lane will fail intermittently under load." -ForegroundColor Red
New-PagerDutyIncident -Title "Zava quiz errors under load — intermittent failures" `
  -Details "Students using the quiz lane on port 8086 see intermittent quiz errors under load. Demo monitoring observed intermittent failures." | Out-Null
