# Check-Prerequisites.ps1 — verifies required tools are installed
# Dot-source from any script: . "$PSScriptRoot\Check-Prerequisites.ps1"

function Get-PythonPrerequisite {
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $usablePython = $null

    foreach ($name in @('python3', 'python', 'py')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $command) { continue }

        $executable = $command.Source
        if (-not $executable -or -not $seen.Add($executable)) { continue }

        & $executable -c 'import sys; raise SystemExit(0 if sys.version_info.major == 3 else 1)' *> $null
        if ($LASTEXITCODE -ne 0) { continue }

        if (-not $usablePython) { $usablePython = $executable }

        & $executable -c 'import yaml' *> $null
        if ($LASTEXITCODE -eq 0) {
            return [PSCustomObject]@{
                Command = $executable
                HasYaml = $true
            }
        }
    }

    return [PSCustomObject]@{
        Command = $usablePython
        HasYaml = $false
    }
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
        $python = Get-PythonPrerequisite
        if (-not $python.Command) {
            $missing += "Python 3 — install: https://www.python.org/downloads/"
        }
        elseif (-not $python.HasYaml) {
            $missing += "PyYAML — install: $($python.Command) -m pip install pyyaml"
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
