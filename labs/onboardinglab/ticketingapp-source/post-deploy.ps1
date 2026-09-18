#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$setup = Join-Path $PSScriptRoot '..\scripts\setup.ps1'
if (Test-Path -LiteralPath $setup) {
    & $setup -FromAzdHook
    if ($LASTEXITCODE -ne 0) { throw "Agent setup hook failed (exit $LASTEXITCODE)." }
}
elseif ($env:ONBOARDING_CONFIGURE_AGENT -eq 'true') {
    throw 'Agent setup requires the full onboarding lab checkout.'
}
else {
    Write-Host 'Standalone workload deployed. Use the full onboarding lab checkout to configure an agent.'
}
