#!/bin/bash
# =============================================================================
# Setup GitHub Integration (standalone)
# Run this if you skipped GitHub during initial azd up and want to add it later.
#
# Usage:
#   export GITHUB_PAT=<your-github-pat>
#   ./scripts/setup-github.sh
# =============================================================================
set -e

if [ -z "$GITHUB_PAT" ]; then
  echo "Error: GITHUB_PAT environment variable is not set."
  echo ""
  echo "Usage:"
  echo "  export GITHUB_PAT=<your-github-pat>"
  echo "  ./scripts/setup-github.sh"
  echo ""
  echo "Create a PAT at https://github.com/settings/tokens with 'repo' scope."
  exit 1
fi

echo ""
echo "============================================="
echo "  Adding GitHub Integration to SRE Agent"
echo "============================================="
echo ""

# Configure GitHub MCP connector
echo "Step 1/4: Configuring GitHub MCP connector..."
CONNECTOR_FILE=$(mktemp)
sed "s|PLACEHOLDER_GITHUB_PAT|${GITHUB_PAT}|g" \
  sre-config/connectors/github-mcp.yaml > "$CONNECTOR_FILE"
srectl connector apply -f "$CONNECTOR_FILE"
rm -f "$CONNECTOR_FILE"
echo "  ✓ GitHub MCP connector configured"

# Upload triage runbook
echo "Step 2/4: Uploading GitHub issue triage runbook..."
srectl doc upload --file ./knowledge-base/github-issue-triage.md
echo "  ✓ Uploaded github-issue-triage.md"

# Upgrade incident handler to full version (with GitHub tools)
echo "Step 3/4: Upgrading incident handler with GitHub tools..."
srectl agent apply -f sre-config/agents/incident-handler-full.yaml
echo "  ✓ incident-handler upgraded with GitHub tools"

# Create additional subagents
echo "Step 4/4: Creating code-analyzer and issue-triager subagents..."
srectl agent apply -f sre-config/agents/code-analyzer.yaml
echo "  ✓ code-analyzer subagent created"
srectl agent apply -f sre-config/agents/issue-triager.yaml
echo "  ✓ issue-triager subagent created"

echo ""
echo "============================================="
echo "  ✅ GitHub Integration Configured!"
echo "============================================="
echo ""
echo "  You now have:"
echo "    • GitHub MCP connector (search code, create issues)"
echo "    • code-analyzer subagent (source code RCA)"
echo "    • issue-triager subagent (triage & label issues)"
echo "    • Upgraded incident-handler (now creates GitHub issues)"
echo ""
echo "  Next: Try the Developer and Workflow scenarios in the lab."
echo ""
