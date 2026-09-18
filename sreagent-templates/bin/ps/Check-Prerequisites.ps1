# Check-Prerequisites.ps1 — verifies required tools are installed
# Dot-source from any script: . "$PSScriptRoot\Check-Prerequisites.ps1"

function Resolve-PythonWithYaml {
    $failures = @()
    foreach ($candidate in @('python3', 'python')) {
        $commands = @(Get-Command $candidate -CommandType Application -All -ErrorAction SilentlyContinue)
        foreach ($command in $commands) {
            try {
                $probe = & $command.Source -c "import sys; import yaml; sys.exit('Python 3 required') if sys.version_info.major != 3 else print('sre-python-ready')" 2>&1
                if ($LASTEXITCODE -eq 0 -and $probe -contains 'sre-python-ready') {
                    return $command.Source
                }
                $failures += "$($command.Source): Python 3/PyYAML probe failed (exit $LASTEXITCODE)"
            } catch {
                $failures += "$($command.Source): $($_.Exception.Message)"
            }
        }
    }
    if ($failures.Count -eq 0) { $failures += 'python3 and python were not found in PATH' }
    throw "Python 3 with PyYAML is required. $($failures -join '; '). Install PyYAML using the intended interpreter: python -m pip install pyyaml"
}

function Test-Prerequisites {
    param(
        [switch]$IncludePython,
        [switch]$IncludeCurl,
        [switch]$IncludeTar
    )

    $missing = @()

    # az CLI
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        $missing += "az CLI — install: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
    }

    # jq
    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        $install = if ($IsWindows) { "winget install stedolan.jq  or  choco install jq" }
                   elseif ($IsMacOS) { "brew install jq" }
                   else { "apt install jq" }
        $missing += "jq — install: $install"
    }

    # Python 3 + PyYAML
    if ($IncludePython) {
        try {
            $py = Resolve-PythonWithYaml
            # Legacy consumers invoke python3 directly; keep them on the tested interpreter.
            Set-Alias -Name python3 -Value $py -Scope Script
        } catch {
            $missing += $_.Exception.Message
        }
    }

    # curl
    if ($IncludeCurl -and -not (Get-Command curl -ErrorAction SilentlyContinue)) {
        $missing += "curl — should be pre-installed"
    }

    # tar
    if ($IncludeTar -and -not (Get-Command tar -ErrorAction SilentlyContinue)) {
        $missing += "tar — should be pre-installed"
    }

    # PowerShell version check
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $missing += "PowerShell 7+ required (current: $($PSVersionTable.PSVersion)). Install: https://aka.ms/powershell"
    }

    if ($missing.Count -gt 0) {
        Write-Host "Missing prerequisites:" -ForegroundColor Red
        foreach ($m in $missing) {
            Write-Host "  - $m" -ForegroundColor Yellow
        }
        return $false
    }
    return $true
}
