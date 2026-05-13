#!/bin/bash
# =============================================================================
# prereqs.sh — Check prerequisites for Deployment Compliance Demo
# Works on macOS (brew) and Windows (winget via Git Bash)
# Run this before 'azd provision' if tools are missing.
# =============================================================================

echo ""
echo "============================================="
echo "  Deployment Compliance Demo — Prerequisites"
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
    elif [ "$OS" = "windows" ]; then
      echo "     Install: $install_win"
    else
      echo "     Install: see https://learn.microsoft.com/cli/azure/install-azure-cli"
    fi
    MISSING=$((MISSING + 1))
  fi
}

echo "Checking tools:"
check_tool "Azure CLI" "az" "brew install azure-cli" "winget install Microsoft.AzureCLI"
check_tool "Azure Developer CLI" "azd" "brew install azd" "winget install Microsoft.Azd"
check_tool "Git" "git" "brew install git" "winget install Git.Git"
check_tool "Python" "python3" "brew install python3" "winget install Python.Python.3.12"
check_tool "jq" "jq" "brew install jq" "winget install jqlang.jq"

# Python fallback for Windows (python instead of python3)
if ! command -v python3 &>/dev/null && command -v python &>/dev/null; then
  version=$(python --version 2>&1)
  if echo "$version" | grep -q "Python 3"; then
    echo "  ✅ Python (via 'python'): $version"
    MISSING=$((MISSING - 1))
  fi
fi

echo ""

# Check Azure login
echo "Checking Azure auth:"
if az account show &>/dev/null 2>&1; then
  sub=$(az account show --query name -o tsv 2>/dev/null)
  echo "  ✅ Logged in: $sub"
else
  echo "  ❌ Not logged in to Azure"
  echo "     Run: az login"
  MISSING=$((MISSING + 1))
fi

# Check resource provider
echo ""
echo "Checking resource provider:"
APP_STATE=$(az provider show -n Microsoft.App --query "registrationState" -o tsv 2>/dev/null)
if [ "$APP_STATE" = "Registered" ]; then
  echo "  ✅ Microsoft.App: Registered"
else
  echo "  ⚠️  Microsoft.App: $APP_STATE"
  echo "     Run: az provider register -n Microsoft.App --wait"
  MISSING=$((MISSING + 1))
fi

echo ""
echo "============================================="
if [ "$MISSING" -eq 0 ]; then
  echo "  ✅ All prerequisites met! Run: azd provision"
else
  echo "  ⚠️  $MISSING issue(s) found — fix above then re-run"
fi
echo "============================================="
echo ""

# Windows-specific tips
if [ "$OS" = "windows" ]; then
  echo "💡 Windows tips:"
  echo "   • Disable Python Store aliases: Settings → Apps → Advanced → App execution aliases"
  echo "   • If 'azd provision' fails with 'bash not found', run post-deploy manually:"
  echo "     \"C:\\Program Files\\Git\\bin\\bash.exe\" scripts/post-deploy.sh"
  echo ""
fi
