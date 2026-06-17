#!/bin/bash
# ============================================================
# setup-github-workflow.sh — Wire a GitHub repo to the SRE Agent
# Copies the PR guard workflow and sets the webhook secret.
#
# Usage:
#   bash setup-github-workflow.sh \
#     --repo <org/repo> \
#     --webhook-url <logic-app-trigger-url>
# ============================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REPO=""
WEBHOOK_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --webhook-url) WEBHOOK_URL="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO" || -z "$WEBHOOK_URL" ]]; then
  echo "Usage: $0 --repo <org/repo> --webhook-url <url>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECIPE_DIR="$(cd "$SCRIPT_DIR/../../sreagent-templates/recipes/law-dynatrace-httptrigger" && pwd)"
WORKFLOW_SRC="$RECIPE_DIR/data/sample-github-workflow.yml"

if [[ ! -f "$WORKFLOW_SRC" ]]; then
  echo -e "${RED}Workflow template not found at $WORKFLOW_SRC${NC}"
  exit 1
fi

# Clone the repo to a temp dir, add workflow, push
TMPDIR=$(mktemp -d)
echo -e "${YELLOW}Cloning $REPO...${NC}"
gh repo clone "$REPO" "$TMPDIR/repo" -- --depth 1

mkdir -p "$TMPDIR/repo/.github/workflows"
cp "$WORKFLOW_SRC" "$TMPDIR/repo/.github/workflows/sre-agent-pr-guard.yml"

cd "$TMPDIR/repo"
git add .github/workflows/sre-agent-pr-guard.yml
if git diff --cached --quiet; then
  echo -e "${GREEN}Workflow already exists. Skipping.${NC}"
else
  git commit -m "Add SRE Agent PR deployment guard workflow"
  git push
  echo -e "${GREEN}✓ Workflow pushed to $REPO${NC}"
fi

# Set the webhook secret
echo -e "${YELLOW}Setting SRE_AGENT_WEBHOOK_URL secret...${NC}"
gh secret set SRE_AGENT_WEBHOOK_URL --repo "$REPO" --body "$WEBHOOK_URL"
echo -e "${GREEN}✓ Secret set on $REPO${NC}"

# Clean up
rm -rf "$TMPDIR"
echo -e "${GREEN}Done! PRs on $REPO will now trigger the SRE Agent deployment guard.${NC}"
