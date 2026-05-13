#!/bin/bash
# =============================================================================
# prereqs.sh — Install prerequisites for SRE Agent Lab
# Works on macOS (brew) and Windows (winget via Git Bash)
# Run this before 'azd up' if tools are missing.
# =============================================================================

echo ""
echo "============================================="
echo "  SRE Agent Lab — Prerequisites Check"
echo "============================================="
echo ""

MISSING=0

# Detect OS
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin" ]]; then
  OS="windows"
elif [[ "$OSTYPE" == "darwin"* ]]; then
  OS="mac"
else
  OS="linux"
fi

echo "Platform: $OS"
echo ""

# Check each tool
check_tool() {
  local name="$1"
  local cmd="$2"
  local install_mac="$3"
  local install_win="$4"

  if command -v "$cmd" &>/dev/null; then
    version=$($cmd --version 2>&1 | head -1)
    echo "  ✅ $name: $version"
  else
    echo "  ❌ $name: NOT FOUND"
    if [ "$OS" = "mac" ]; then
      echo "     Install: $install_mac"
    else
      echo "     Install: $install_win"
    fi
    MISSING=$((MISSING + 1))
  fi
}

echo "Checking tools:"
check_tool "Azure CLI" "az" "brew install azure-cli" "winget install Microsoft.AzureCLI"
check_tool "Azure Developer CLI" "azd" "brew install azd" "winget install Microsoft.Azd"
check_tool "Git" "git" "brew install git" "winget install Git.Git"

# Python: check python3 first, fall back to python (Windows uses 'python' not 'python3')
PYTHON_CMD=""
if command -v python3 &>/dev/null; then
  version=$(python3 --version 2>&1 | head -1)
  echo "  ✅ Python: $version"
  PYTHON_CMD=python3
elif command -v python &>/dev/null; then
  version=$(python --version 2>&1)
  if echo "$version" | grep -q "Python 3"; then
    echo "  ✅ Python: $version"
    PYTHON_CMD=python
  else
    echo "  ❌ Python: Found $version but need Python 3.10+"
    echo "     Install: winget install Python.Python.3.12"
    MISSING=$((MISSING + 1))
  fi
else
  echo "  ❌ Python: NOT FOUND"
  if [ "$OS" = "mac" ]; then
    echo "     Install: brew install python3"
  else
    echo "     Install: winget install Python.Python.3.12"
  fi
  MISSING=$((MISSING + 1))
fi

# Check pyyaml module (needed by post-provision script)
if [ -n "$PYTHON_CMD" ]; then
  if $PYTHON_CMD -c "import yaml" 2>/dev/null; then
    echo "  ✅ PyYAML: installed"
  else
    echo "  ⚠️  PyYAML: not installed — installing..."
    $PYTHON_CMD -m pip install pyyaml --quiet 2>/dev/null && echo "  ✅ PyYAML: installed" || echo "  ❌ PyYAML: failed — run: pip install pyyaml"
  fi
fi

echo ""

# Check Azure login (informational — login happens after prereqs)
echo "Checking Azure auth:"
if az account show &>/dev/null 2>&1; then
  sub=$(az account show --query name -o tsv 2>/dev/null)
  echo "  ✅ Logged in: $sub"
else
  echo "  ℹ️  Not logged in yet — run 'az login' before 'azd up'"
fi

# Check resource provider (requires login)
echo ""
echo "Checking resource provider:"
if az account show &>/dev/null 2>&1; then
  APP_STATE=$(az provider show -n Microsoft.App --query "registrationState" -o tsv 2>/dev/null)
  if [ "$APP_STATE" = "Registered" ]; then
    echo "  ✅ Microsoft.App: Registered"
  else
    echo "  ℹ️  Microsoft.App: ${APP_STATE:-not checked}"
    echo "     Run after login: az provider register -n Microsoft.App --wait"
  fi
else
  echo "  ℹ️  Skipped (login required) — run after 'az login':"
  echo "     az provider register -n Microsoft.App --wait"
fi

echo ""
echo "============================================="
if [ "$MISSING" -eq 0 ]; then
  echo "  ✅ All prerequisites met! Run: azd up"
else
  echo "  ⚠️  $MISSING issue(s) found — fix above then re-run"
fi
echo "============================================="
echo ""

# Windows-specific tips
if [ "$OS" = "windows" ]; then
  echo "💡 Windows tips:"
  echo "   • Disable Python Store aliases: Settings → Apps → Advanced → App execution aliases"
  echo "   • If 'azd up' fails with 'bash not found', run post-provision manually:"
  echo "     \"C:\\Program Files\\Git\\bin\\bash.exe\" scripts/post-provision.sh"
  echo ""
fi
