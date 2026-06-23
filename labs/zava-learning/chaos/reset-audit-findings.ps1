<#
.SYNOPSIS
  Reverse chaos/seed-audit-findings.ps1: remove the standing NSG audit loopholes.
  Strips the over-permissive rules from the reporting-VM NSG, deletes the orphaned
  NSG entirely, and flips the IaC param (seedAuditFindings=false) + git push so the
  committed desired-state matches the live baseline again. Idempotent.
#>
param(
  [string]$ResourceGroup = "rg-zava-learning-demo"
)
. "$PSScriptRoot\_common.ps1"

Write-Host "[reset-audit-findings] Removing standing NSG audit loopholes..." -ForegroundColor Yellow

$token = Get-ResourceToken -ResourceGroup $ResourceGroup
$vmNsg = "nsg-vm-$token"
$orphanNsg = "nsg-legacy-unused-$token"

Write-Host "  1/3 Deleting over-permissive rules from the reporting-VM NSG ($vmNsg)..." -ForegroundColor Gray
foreach ($rule in @("temp-ssh-from-internet","allow-rdp-any","allow-postgres-broad","allow-any-any-legacy")) {
  $exists = az network nsg rule show -g $ResourceGroup --nsg-name $vmNsg -n $rule -o tsv --query name 2>$null
  if ($exists) {
    az network nsg rule delete -g $ResourceGroup --nsg-name $vmNsg -n $rule -o none
    Write-Host "    [deleted] $vmNsg / $rule" -ForegroundColor DarkGray
  }
}

Write-Host "  2/3 Deleting the orphaned NSG ($orphanNsg)..." -ForegroundColor Gray
$orphanExists = az network nsg show -g $ResourceGroup -n $orphanNsg -o tsv --query name 2>$null
if ($orphanExists) {
  az network nsg delete -g $ResourceGroup -n $orphanNsg -o none
  Write-Host "    [deleted] $orphanNsg" -ForegroundColor DarkGray
}
else { Write-Host "  (orphaned NSG already gone)" -ForegroundColor DarkGray }

Write-Host "  3/3 Restoring IaC desired-state (seedAuditFindings=false) in GitHub..." -ForegroundColor Gray
$changed = Set-ParamLine -Pattern '"seedAuditFindings"\s*:\s*\{\s*"value"\s*:\s*true\s*\}' `
                         -Replacement '"seedAuditFindings": { "value": false }'
if ($changed) { Invoke-GitPush -Message "Reset standing NSG audit findings (remove VM NSG + orphaned NSG)" }
else { Write-Host "  (seedAuditFindings already false in source)" -ForegroundColor DarkGray }

Write-Host "[reset-audit-findings] Done. Network baseline restored, live + in source." -ForegroundColor Green
