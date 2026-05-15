# Install-Prerequisites.ps1 — install all required tools for SRE Agent recipes.
#
# Usage:
#   .\bin\ps\Install-Prerequisites.ps1              # install missing tools
#   .\bin\ps\Install-Prerequisites.ps1 -CheckOnly   # check only, don't install
#   .\bin\ps\Install-Prerequisites.ps1 -Terraform   # also install Terraform
#   .\bin\ps\Install-Prerequisites.ps1 -All         # install everything

param(
    [switch]$CheckOnly,
    [switch]$Terraform,
    [switch]$Azd,
    [switch]$All
)

if ($All) { $Terraform = $true; $Azd = $true }

$Missing = [System.Collections.Generic.List[string]]::new()
$Installed = [System.Collections.Generic.List[string]]::new()
$Skipped = [System.Collections.Generic.List[string]]::new()

function Test-Tool {
    param([string]$Name, [string]$Command, [string]$VersionArg = "--version")
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = ""
        try { $ver = & $Command $VersionArg 2>&1 | Select-Object -First 1 } catch {}
        Write-Host "  ✅ $Name $ver"
        return $true
    } else {
        Write-Host "  ❌ $Name" -ForegroundColor Red
        $script:Missing.Add($Name)
        return $false
    }
}

function Install-WithWinget {
    param([string]$PackageId, [string]$Name)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  ⚠ winget not available — install $Name manually" -ForegroundColor Yellow
        $script:Skipped.Add($Name)
        return
    }
    Write-Host "  Installing $Name via winget..."
    winget install --id $PackageId --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -eq 0) {
        $script:Installed.Add($Name)
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                     [System.Environment]::GetEnvironmentVariable("Path", "User")
    } else {
        $script:Skipped.Add($Name)
    }
}

# ── Main ──
Write-Host "═══════════════════════════════════════════════════"
Write-Host "  SRE Agent — Prerequisites Check"
Write-Host "  OS: Windows (PowerShell $($PSVersionTable.PSVersion))"
Write-Host "═══════════════════════════════════════════════════"
Write-Host

# PowerShell version
Write-Host "── PowerShell ──"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "  ✅ PowerShell $($PSVersionTable.PSVersion)"
} else {
    Write-Host "  ❌ PowerShell 7+ required (current: $($PSVersionTable.PSVersion))" -ForegroundColor Red
    Write-Host "     Install: https://aka.ms/powershell" -ForegroundColor Yellow
    $Missing.Add("PowerShell 7+")
}
Write-Host

# Required tools
Write-Host "── Required tools ──"
Test-Tool "az CLI" "az" "version" | Out-Null
Test-Tool "jq" "jq" "--version" | Out-Null
Test-Tool "curl" "curl" "--version" | Out-Null

# Python + PyYAML
$py = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if ($py) {
    # Verify it's real Python, not the Windows Store stub
    $testResult = & $py.Source -c "print('ok')" 2>&1
    if ($testResult -eq "ok") {
        Write-Host "  ✅ Python $( & $py.Source --version 2>&1)"
        $yamlCheck = & $py.Source -c "import yaml" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ PyYAML"
        } else {
            Write-Host "  ❌ PyYAML" -ForegroundColor Red
            $Missing.Add("PyYAML")
        }
    } else {
        Write-Host "  ❌ Python 3 (Windows Store stub detected — install real Python)" -ForegroundColor Red
        $Missing.Add("Python 3")
    }
} else {
    Write-Host "  ❌ Python 3" -ForegroundColor Red
    $Missing.Add("Python 3")
}
Write-Host

# Optional: Terraform
if ($Terraform) {
    Write-Host "── Terraform (optional) ──"
    Test-Tool "terraform" "terraform" "version" | Out-Null
    Write-Host
}

# Optional: azd
if ($Azd) {
    Write-Host "── Azure Developer CLI (optional) ──"
    Test-Tool "azd" "azd" "version" | Out-Null
    Write-Host
}

if ($Missing.Count -eq 0) {
    Write-Host "All prerequisites installed! ✅" -ForegroundColor Green
    exit 0
}

if ($CheckOnly) {
    Write-Host "$($Missing.Count) tool(s) missing." -ForegroundColor Yellow
    exit 1
}

# ── Install missing ──
Write-Host "── Installing $($Missing.Count) missing tool(s) ──"
Write-Host

foreach ($tool in $Missing) {
    switch -Wildcard ($tool) {
        "az CLI" {
            Install-WithWinget "Microsoft.AzureCLI" "az CLI"
        }
        "jq" {
            Install-WithWinget "jqlang.jq" "jq"
        }
        "Python 3" {
            Install-WithWinget "Python.Python.3.12" "Python 3"
            # After install, create python3 alias if needed
            $pythonPath = Get-Command python -ErrorAction SilentlyContinue
            if ($pythonPath) {
                $dir = Split-Path $pythonPath.Source
                $python3 = Join-Path $dir "python3.exe"
                if (-not (Test-Path $python3)) {
                    Copy-Item $pythonPath.Source $python3
                    Write-Host "  Created python3.exe alias"
                }
            }
        }
        "PyYAML" {
            Write-Host "  Installing PyYAML..."
            $pipPy = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
            if ($pipPy) {
                & $pipPy.Source -m pip install pyyaml 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $Installed.Add("PyYAML") } else { $Skipped.Add("PyYAML") }
            } else { $Skipped.Add("PyYAML") }
        }
        "terraform" {
            Install-WithWinget "Hashicorp.Terraform" "terraform"
        }
        "azd" {
            Install-WithWinget "Microsoft.Azd" "azd"
        }
        "PowerShell 7+" {
            Write-Host "  ⚠ Install PowerShell 7 manually: https://aka.ms/powershell" -ForegroundColor Yellow
            $Skipped.Add("PowerShell 7+")
        }
    }
}

Write-Host
Write-Host "═══════════════════════════════════════════════════"
if ($Installed.Count -gt 0) {
    Write-Host "  Installed: $($Installed -join ', ')" -ForegroundColor Green
}
if ($Skipped.Count -gt 0) {
    Write-Host "  ⚠ Could not install: $($Skipped -join ', ')" -ForegroundColor Yellow
    Write-Host "    Install manually — see links above."
}
Write-Host "═══════════════════════════════════════════════════"

# ── Verify ──
Write-Host
Write-Host "── Verifying ──"
$Missing.Clear()
Test-Tool "az CLI" "az" "version" | Out-Null
Test-Tool "jq" "jq" "--version" | Out-Null
Test-Tool "curl" "curl" "--version" | Out-Null

$py2 = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $py2) { $py2 = Get-Command python -ErrorAction SilentlyContinue }
if ($py2) {
    $yamlCheck = & $py2.Source -c "import yaml" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✅ PyYAML" } else { $Missing.Add("PyYAML") }
}

if ($Terraform) { Test-Tool "terraform" "terraform" "version" | Out-Null }
if ($Azd) { Test-Tool "azd" "azd" "version" | Out-Null }

if ($Missing.Count -eq 0) {
    Write-Host
    Write-Host "All prerequisites installed! ✅" -ForegroundColor Green
    Write-Host 'Next: .\bin\ps\New-Agent.ps1 -Recipe azmon-lawappinsights'
} else {
    Write-Host
    Write-Host "$($Missing.Count) tool(s) still missing — install manually." -ForegroundColor Yellow
    exit 1
}
