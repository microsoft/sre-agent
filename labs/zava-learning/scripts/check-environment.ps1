<#
.SYNOPSIS
  Verifies the tooling needed to deploy and run the Zava Learning lab.
#>
$ErrorActionPreference = "Continue"
$ok = $true
function Check($name, $cmd) {
  $v = & $cmd 2>$null
  if ($LASTEXITCODE -eq 0 -and $v) { Write-Host "  ✅ $name" -ForegroundColor Green }
  else { Write-Host "  ✗ $name (missing)" -ForegroundColor Red; $script:ok = $false }
}
Write-Host "Zava Learning — environment check" -ForegroundColor Cyan
Check "Azure CLI"        { az version --query '"azure-cli"' -o tsv }
Check "Bicep"            { az bicep version }
Check "Azure Developer CLI (azd)" { azd version }
Check "PowerShell 7+ (pwsh)" { pwsh -v }
Check "Python 3"         { python --version }
Check "Logged into Azure" { az account show --query id -o tsv }

if ($ok) { Write-Host "`nAll good. You can run: azd up  (or scripts/post-provision.ps1 after az deployment)." -ForegroundColor Green }
else { Write-Host "`nResolve the missing items above before deploying." -ForegroundColor Yellow }
