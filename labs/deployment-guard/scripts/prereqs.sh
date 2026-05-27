#!/bin/bash
# ============================================================
# prereqs.sh — Check prerequisites for Deployment Guard Lab
# ============================================================
set -euo pipefail

echo ""
echo "============================================="
echo "  Deployment Guard Lab — Prerequisites"
echo "============================================="
echo ""

MISSING=0

check_tool() {
  local name="$1"
  local cmd="$2"
  if command -v "$cmd" &>/dev/null; then
    version=$($cmd --version 2>&1 | head -1)
    echo "  ✅ $name: $version"
  else
    echo "  ❌ $name: NOT FOUND"
    MISSING=$((MISSING + 1))
  fi
}

check_tool "Azure CLI" "az"
check_tool "GitHub CLI" "gh"
check_tool "jq" "jq"

echo ""

# Check az login
if az account show &>/dev/null; then
  ACCOUNT=$(az account show --query name -o tsv)
  echo "  ✅ Logged into Azure: $ACCOUNT"
else
  echo "  ❌ Not logged into Azure (run: az login)"
  MISSING=$((MISSING + 1))
fi

# Check gh auth
if gh auth status &>/dev/null; then
  echo "  ✅ Logged into GitHub"
else
  echo "  ❌ Not logged into GitHub (run: gh auth login)"
  MISSING=$((MISSING + 1))
fi

echo ""
if [[ $MISSING -eq 0 ]]; then
  echo "  All prerequisites met! ✅"
else
  echo "  $MISSING prerequisite(s) missing. Fix them before proceeding."
  exit 1
fi
