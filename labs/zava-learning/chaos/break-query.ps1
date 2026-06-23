<#
.SYNOPSIS
  Query lane: simulates question_bank index corruption on zava_query. A corrupt index can no
  longer serve scans, so the planner falls back to a full table scan of the 500k-row question
  bank and quiz loading slows. Remediation is a REINDEX/rebuild of the index (fix-query.ps1).

  NOTE: Azure PostgreSQL Flexible Server has no superuser, so pg_index.indisvalid cannot be
  flipped directly. We reproduce the identical end state of a corrupt/unusable index (planner
  full-scan) by removing it here; fix-query rebuilds it (the equivalent of a REINDEX).
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[break-query] Simulating question_bank index corruption on zava_query..." -ForegroundColor Yellow
Invoke-PgSql -ResourceGroup $ResourceGroup -Database "zava_query" `
  -Sql "DROP INDEX IF EXISTS idx_question_bank_course;"

Write-Host "[break-query] Index corruption in effect. Quiz loading on the query lane will slow down." -ForegroundColor Red
New-PagerDutyIncident -Title "Zava quiz loading slowly — elevated latency" `
  -Details "Students using the quiz lane on port 8085 experience slow quiz loading. Demo monitoring observed elevated latency." | Out-Null
