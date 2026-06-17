#!/bin/bash
# ============================================================
# demo.sh — Run the deployment guard demo end-to-end
#
# This script creates a risky PR on contoso-trading and watches
# the SRE Agent analyze it via the HTTP trigger.
#
# Usage:
#   bash demo.sh --repo <org/repo> [--app-dir <local-clone-path>]
#
# Prerequisites:
#   - SRE Agent deployed with law-dynatrace-httptrigger recipe
#   - GitHub workflow + webhook secret configured (setup-github-workflow.sh)
#   - contoso-trading cloned locally
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO=""
APP_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Usage: $0 --repo <org/repo> [--app-dir <local-clone-path>]"
  exit 1
fi

# Default app dir to ~/contoso-trading
APP_DIR="${APP_DIR:-$HOME/contoso-trading}"

if [[ ! -d "$APP_DIR" ]]; then
  echo -e "${RED}contoso-trading not found at $APP_DIR${NC}"
  echo "Clone it first: gh repo clone $REPO $APP_DIR"
  exit 1
fi

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Deployment Guard Demo${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# ─────────────────────────────────────────────────────────
# PREP: Clean up any previous demo branches
# ─────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[PREP] Cleaning up previous demo state...${NC}"
cd "$APP_DIR"
git checkout main 2>/dev/null && git pull
git branch -D config-cleanup 2>/dev/null || true
git push origin --delete config-cleanup 2>/dev/null || true

# Close any existing demo PRs
EXISTING_PR=$(gh pr list --repo "$REPO" --head config-cleanup --json number -q '.[0].number' 2>/dev/null || echo "")
if [[ -n "$EXISTING_PR" ]]; then
  gh pr close "$EXISTING_PR" --repo "$REPO" --delete-branch 2>/dev/null || true
fi
echo -e "${GREEN}  ✓ Clean state${NC}"

# ─────────────────────────────────────────────────────────
# ACT 1: Create a risky change
# ─────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[ACT 1] Creating a subtle breaking change...${NC}"
git checkout -b config-cleanup

# Rename DATABASE_URL to DB_CONNECTION_URL — looks like a cleanup
# but breaks payment-service because the env var is still DATABASE_URL
sed -i '' 's|DATABASE_URL|DB_CONNECTION_URL|g' payment-service/Program.cs 2>/dev/null \
  || sed -i 's|DATABASE_URL|DB_CONNECTION_URL|g' payment-service/Program.cs 2>/dev/null

git add -A
git commit -m "Standardize database env var naming"
git push origin config-cleanup --force
echo -e "${GREEN}  ✓ Pushed config-cleanup branch${NC}"

# ─────────────────────────────────────────────────────────
# ACT 2: Open the PR — this triggers the webhook
# ─────────────────────────────────────────────────────────
echo -e "\n${YELLOW}[ACT 2] Creating PR...${NC}"
PR_URL=$(gh pr create \
  --repo "$REPO" \
  --title "Standardize database env var naming" \
  --body "Renamed DATABASE_URL to DB_CONNECTION_URL for consistency with other services." \
  --base main \
  --head config-cleanup \
  --json url -q '.url' 2>/dev/null || \
  gh pr view config-cleanup --repo "$REPO" --json url -q '.url')

echo -e "${GREEN}  ✓ PR created: $PR_URL${NC}"
echo ""
echo -e "${BLUE}The GitHub Actions workflow is now sending the PR event to the SRE Agent.${NC}"
echo -e "${BLUE}Watch the PR for the agent's risk assessment comment.${NC}"
echo ""
echo -e "${YELLOW}Check progress:${NC}"
echo "  GitHub Actions: gh run list --repo $REPO --limit 3"
echo "  PR comments:    gh pr view config-cleanup --repo $REPO --comments"
echo ""

# ─────────────────────────────────────────────────────────
# ACT 3: Wait and show the result
# ─────────────────────────────────────────────────────────
echo -e "${YELLOW}[ACT 3] Waiting for agent to analyze the PR...${NC}"
echo "  This typically takes 5-10 minutes (baseline capture + canary testing)."
echo ""
echo "  To check manually:"
echo "    gh pr view config-cleanup --repo $REPO --comments"
echo ""

# Poll for PR comment (up to 15 minutes)
for i in $(seq 1 30); do
  COMMENTS=$(gh pr view config-cleanup --repo "$REPO" --json comments --jq '.comments | length' 2>/dev/null || echo "0")
  if [[ "$COMMENTS" -gt 0 ]]; then
    echo -e "\n${GREEN}  ✓ Agent posted a comment on the PR!${NC}"
    echo ""
    gh pr view config-cleanup --repo "$REPO" --comments 2>/dev/null | tail -40
    break
  fi
  echo "  Waiting... ($((i * 30))s elapsed, $COMMENTS comments so far)"
  sleep 30
done

# ─────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[CLEANUP] To clean up after the demo:${NC}"
echo "  gh pr close config-cleanup --repo $REPO --delete-branch"
echo "  cd $APP_DIR && git checkout main"
