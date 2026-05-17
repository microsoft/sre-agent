#!/bin/bash
# =============================================================================
# prereqs.sh — Prerequisites + interactive prompts for Zava Zava Café Lab
# Runs as the azd preprovision hook.
# =============================================================================

echo ""
echo "============================================="
echo "  Zava — Zava Café Lab — Prereqs Check"
echo "============================================="
echo ""

MISSING=0

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin" ]]; then
  OS="windows"
elif [[ "$OSTYPE" == "darwin"* ]]; then
  OS="mac"
else
  OS="linux"
fi
echo "Platform: $OS"
echo ""

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

# Python (used by the post-provision script for shaping JSON, etc.)
PYTHON_CMD=""
if command -v python3 &>/dev/null; then
  echo "  ✅ Python: $(python3 --version 2>&1)"
  PYTHON_CMD=python3
elif command -v python &>/dev/null; then
  v=$(python --version 2>&1)
  if echo "$v" | grep -q "Python 3"; then
    echo "  ✅ Python: $v"
    PYTHON_CMD=python
  else
    echo "  ❌ Python: $v — need Python 3.10+"
    MISSING=$((MISSING + 1))
  fi
else
  echo "  ❌ Python: NOT FOUND"
  MISSING=$((MISSING + 1))
fi

# sqlcmd — only used to seed the DB; warn if missing but don't hard-fail
if command -v sqlcmd &>/dev/null; then
  echo "  ✅ sqlcmd: $(sqlcmd -? 2>&1 | head -1 | tr -d '\r')"
else
  echo "  ⚠️  sqlcmd: NOT FOUND — DB seeding will be skipped."
  echo "     Install: winget install Microsoft.Sqlcmd  (or use ODBC sqlcmd from SQL Server Tools)"
fi

echo ""

# ── Entra admin — must be set so Bicep can configure SQL Server AAD-only ────
echo "Checking Entra admin (will be SQL Server admin)..."
AAD_LOGIN="$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null | tr -d '\r')"
AAD_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null | tr -d '\r')"
if [ -z "$AAD_LOGIN" ] || [ -z "$AAD_OID" ]; then
  echo "  ✗ Could not query az signed-in user. Run 'az login' first."
  exit 1
fi
echo "  ✓ Will use $AAD_LOGIN as SQL Entra admin"
azd env set AAD_ADMIN_LOGIN "$AAD_LOGIN" 2>/dev/null || true
azd env set AAD_ADMIN_OBJECT_ID "$AAD_OID" 2>/dev/null || true

# ── Python deps for sql_entra.py (pyodbc + azure-identity) ──────────────────
if [ -n "$PYTHON_CMD" ]; then
  echo ""
  echo "Checking Python deps for SQL helper (pyodbc, azure-identity):"
  if $PYTHON_CMD -c "import pyodbc, azure.identity" 2>/dev/null; then
    echo "  ✅ pyodbc + azure-identity already installed"
  else
    echo "  ⚠️  Installing pyodbc + azure-identity (best-effort)..."
    if $PYTHON_CMD -m pip install --quiet --disable-pip-version-check pyodbc azure-identity 2>/dev/null; then
      echo "  ✅ pyodbc + azure-identity installed"
    else
      echo "  ⚠️  pip install failed — SQL seed/grant steps will be skipped."
      echo "     Manually: $PYTHON_CMD -m pip install pyodbc azure-identity"
    fi
  fi
fi

# ── Azure auth (informational) ───────────────────────────────────────────────
echo ""
echo "Checking Azure auth:"
if az account show &>/dev/null 2>&1; then
  sub=$(az account show --query name -o tsv 2>/dev/null)
  echo "  ✅ Logged in: $sub"
else
  echo "  ℹ️  Not logged in yet — run 'az login' before 'azd up'"
fi

echo ""
echo "============================================="
if [ "$MISSING" -eq 0 ]; then
  echo "  ✅ Prerequisites met! Proceeding with azd provision..."
else
  echo "  ❌ $MISSING required tool(s) missing — fix above then re-run"
  exit 1
fi
echo "============================================="
echo ""
