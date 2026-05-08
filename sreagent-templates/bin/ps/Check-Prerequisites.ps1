# Check-Prerequisites.ps1 — verifies required tools are installed
# Dot-source from any script: . "$PSScriptRoot\Check-Prerequisites.ps1"

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
        $py = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $py) {
            $missing += "Python 3 — install: https://www.python.org/downloads/"
        } else {
            $hasYaml = & $py.Source -c "import yaml" 2>&1
            if ($LASTEXITCODE -ne 0) {
                $missing += "PyYAML — install: pip install pyyaml"
            }
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
