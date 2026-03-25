#!/bin/bash
# =============================================================================
# setup.sh — One-command lab setup for Azure SRE Agent Starter Lab
#
# Handles: prerequisites, Azure login, deploy, and agent configuration.
# Usage: "C:\Program Files\Git\bin\bash.exe" scripts/setup.sh
# =============================================================================

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Azure SRE Agent — Starter Lab Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# ── Step 1: Check Prerequisites ──────────────────────────────────────────────
echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"

MISSING=0
for cmd in az azd git; do
  if command -v $cmd &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $cmd"
  else
    echo -e "  ${RED}✗ $cmd not found${NC}"
    MISSING=$((MISSING + 1))
  fi
done

# Python check
if command -v python3 &>/dev/null; then
  echo -e "  ${GREEN}✓${NC} python3"
elif command -v python &>/dev/null; then
  ver=$(python --version 2>&1)
  if echo "$ver" | grep -q "Python 3"; then
    echo -e "  ${GREEN}✓${NC} python ($ver)"
  else
    echo -e "  ${RED}✗ Python 3 not found (have $ver)${NC}"
    MISSING=$((MISSING + 1))
  fi
else
  echo -e "  ${RED}✗ Python not found${NC}"
  echo -e "    Install: ${YELLOW}winget install Python.Python.3.12${NC}"
  echo -e "    Then disable Store aliases: Settings → Apps → App execution aliases"
  MISSING=$((MISSING + 1))
fi

# Install pyyaml if needed
if command -v python3 &>/dev/null; then
  python3 -c "import yaml" 2>/dev/null || python3 -m pip install pyyaml --quiet 2>/dev/null
elif command -v python &>/dev/null; then
  python -c "import yaml" 2>/dev/null || python -m pip install pyyaml --quiet 2>/dev/null
fi

if [ "$MISSING" -gt 0 ]; then
  echo -e "\n${RED}  $MISSING tool(s) missing. Install them and re-run this script.${NC}"
  exit 1
fi
echo -e "  ${GREEN}All prerequisites met!${NC}"
echo ""

# ── Step 2: Azure Login ──────────────────────────────────────────────────────
echo -e "${YELLOW}[2/6] Signing in to Azure...${NC}"

# Always force fresh login to avoid stale/wrong sessions
echo -e "  Running ${YELLOW}az login --use-device-code${NC}"
echo -e "  Open a browser inside the VM, go to ${YELLOW}https://microsoft.com/devicelogin${NC}"
echo -e "  Enter the code shown below, then sign in with your lab credentials."
echo ""
az login --use-device-code
if [ $? -ne 0 ]; then
  echo -e "${RED}  Azure login failed. Try again.${NC}"
  exit 1
fi

# Set subscription if provided
SUB_ID="${1:-}"
if [ -n "$SUB_ID" ]; then
  az account set --subscription "$SUB_ID" 2>/dev/null
  echo -e "  ${GREEN}✓${NC} Subscription set: $SUB_ID"
fi
echo ""

# Register provider
echo -e "  Registering Microsoft.App provider..."
az provider register -n Microsoft.App --wait --output none 2>/dev/null
echo -e "  ${GREEN}✓${NC} Microsoft.App registered"
echo ""

# azd auth
echo -e "  Signing in to Azure Developer CLI..."
if azd auth login --check-status &>/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} Already signed in to azd"
else
  azd auth login --use-device-code
fi
echo ""

# ── Step 3: Environment Setup ────────────────────────────────────────────────
echo -e "${YELLOW}[3/6] Setting up environment...${NC}"

ENV_NAME="${2:-sre-lab}"
azd env new "$ENV_NAME" 2>/dev/null || azd env select "$ENV_NAME" 2>/dev/null
azd env set AZURE_LOCATION eastus2 2>/dev/null
echo -e "  ${GREEN}✓${NC} Environment: $ENV_NAME (eastus2)"

# GitHub (optional)
echo ""
echo -e "  ${BLUE}Optional: GitHub Integration${NC}"
echo -e "  This enables source code analysis and issue triage."
read -p "  Enter your GitHub username (or press Enter to skip): " GITHUB_USER

if [ -n "$GITHUB_USER" ]; then
  azd env set GITHUB_USER "$GITHUB_USER" 2>/dev/null
  echo -e "  ${GREEN}✓${NC} GitHub user: $GITHUB_USER"
else
  echo -e "  ${YELLOW}⏭️${NC}  Skipped — core lab works without GitHub"
fi
echo ""

# ── Step 4: Deploy Infrastructure ────────────────────────────────────────────
echo -e "${YELLOW}[4/6] Deploying infrastructure (~5-8 min)...${NC}"
echo -e "  This creates: SRE Agent, Grubify app, monitoring, alerts"
echo ""

# Refresh azd auth right before deploy (TAP tokens expire quickly)
echo -e "  Refreshing Azure Developer CLI auth..."
azd auth login --use-device-code

azd up
if [ $? -ne 0 ]; then
  echo -e "${RED}  Deployment failed. Check errors above and re-run: azd up${NC}"
  exit 1
fi
echo ""

# ── Step 5: Configure Agent ──────────────────────────────────────────────────
echo -e "${YELLOW}[5/6] Configuring SRE Agent...${NC}"
bash "$SCRIPT_DIR/post-provision.sh"
echo ""

# ── Step 6: Summary ──────────────────────────────────────────────────────────
echo -e "${YELLOW}[6/6] Setup complete!${NC}"
echo ""

CONTAINER_APP_URL=$(azd env get-value CONTAINER_APP_URL 2>/dev/null || echo "")
FRONTEND_URL=$(azd env get-value FRONTEND_APP_URL 2>/dev/null || echo "")

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Lab Ready!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  🤖 Agent Portal:  ${YELLOW}https://sre.azure.com${NC}"
echo -e "  🌐 Grubify API:   ${YELLOW}${CONTAINER_APP_URL:-check Azure Portal}${NC}"
echo -e "  🖥️  Grubify UI:    ${YELLOW}${FRONTEND_URL:-check Azure Portal}${NC}"
echo ""
echo -e "  ${BLUE}Next Steps:${NC}"
echo -e "  1. Open ${YELLOW}https://sre.azure.com${NC} → explore your agent"
echo -e "  2. Open the Grubify app → add items to cart (it works!)"
echo -e "  3. Break it: ${YELLOW}bash scripts/break-app.sh${NC}"
echo -e "  4. Ask the agent to investigate"
echo ""
