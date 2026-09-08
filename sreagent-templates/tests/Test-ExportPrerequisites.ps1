# Verify the PowerShell exporter reports missing PyYAML before contacting Azure.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Exporter = Join-Path $Root 'bin/ps/Export-Agent.ps1'
$Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sre-export-prereq-$([guid]::NewGuid())"
$FakeBin = Join-Path $TempRoot 'bin'
New-Item -ItemType Directory -Path $FakeBin -Force | Out-Null

try {
    $fakePython = @'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == *"import yaml"* ]]; then
  exit 1
fi
exit 0
'@
    foreach ($name in @('python3', 'python')) {
        $path = Join-Path $FakeBin $name
        Set-Content -Path $path -Value $fakePython -NoNewline
        & chmod +x $path
    }

    $oldPath = $env:PATH
    $env:PATH = "$FakeBin$([IO.Path]::PathSeparator)$oldPath"
    $output = & $Pwsh -NoLogo -NoProfile -File $Exporter `
        -Subscription test-subscription `
        -ResourceGroup test-resource-group `
        -AgentName test-agent `
        -NoInstallDependencies 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) { throw 'Exporter unexpectedly succeeded without PyYAML.' }
    $text = $output -join "`n"
    if ($text -notmatch 'Python 3 with PyYAML is required') {
        throw "Missing PyYAML requirement message. Output: $text"
    }
    if ($text -notmatch 'Install-Prerequisites.ps1') {
        throw "Missing prerequisite installer guidance. Output: $text"
    }
    Write-Host 'PASS: PowerShell exporter reports missing PyYAML before Azure export'
} finally {
    if ($oldPath) { $env:PATH = $oldPath }
    Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
}
