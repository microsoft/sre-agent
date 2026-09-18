# Verify the prerequisite checker skips broken Python aliases and reports the
# interpreter that needs PyYAML.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Checker = Join-Path $Root 'bin/ps/Check-Prerequisites.ps1'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sre-check-prereq-$([guid]::NewGuid())"
$FakeBin = Join-Path $TempRoot 'bin'
New-Item -ItemType Directory -Path $FakeBin -Force | Out-Null

function New-FakePython {
    param(
        [string]$Name,
        [ValidateSet('Broken', 'PythonOnly', 'WithYaml')]
        [string]$Behavior
    )

    if ($IsWindows) {
        $path = Join-Path $FakeBin "$Name.cmd"
        $exitCode = switch ($Behavior) {
            'Broken' { 9009 }
            'PythonOnly' { 0 }
            'WithYaml' { 0 }
        }
        $content = if ($Behavior -eq 'PythonOnly') {
            "@echo off`necho %* | findstr /c:`"import yaml`" >nul && exit /b 1`nexit /b 0"
        } else {
            "@echo off`nexit /b $exitCode"
        }
        Set-Content -Path $path -Value $content -NoNewline
    }
    else {
        $path = Join-Path $FakeBin $Name
        $content = switch ($Behavior) {
            'Broken' { "#!/usr/bin/env bash`nexit 127" }
            'PythonOnly' { "#!/usr/bin/env bash`n[[ `"$*`" == *`"import yaml`"* ]] && exit 1`nexit 0" }
            'WithYaml' { "#!/usr/bin/env bash`nexit 0" }
        }
        Set-Content -Path $path -Value $content -NoNewline
        & chmod +x $path
    }
}

try {
    . $Checker
    $oldPath = $env:PATH

    New-FakePython -Name 'python3' -Behavior Broken
    New-FakePython -Name 'python' -Behavior WithYaml
    $env:PATH = "$FakeBin$([IO.Path]::PathSeparator)$oldPath"

    $result = Get-PythonPrerequisite
    if (-not $result.HasYaml -or $result.Command -notmatch 'python') {
        throw "Broken python3 alias did not fall back to python: $($result | Out-String)"
    }

    $extension = if ($IsWindows) { '.cmd' } else { '' }
    Remove-Item (Join-Path $FakeBin "python$extension") -Force
    New-FakePython -Name 'python' -Behavior PythonOnly
    New-FakePython -Name 'py' -Behavior PythonOnly

    $result = Get-PythonPrerequisite
    if ($result.HasYaml -or $result.Command -notmatch 'python') {
        throw "Usable Python without PyYAML was not detected: $($result | Out-String)"
    }

    Write-Host 'PASS: prerequisite checker handles broken aliases and missing PyYAML'
}
finally {
    if ($oldPath) { $env:PATH = $oldPath }
    Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
}
