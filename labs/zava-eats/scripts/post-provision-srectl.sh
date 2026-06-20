#!/bin/bash
# =============================================================================
# Post-Provision Script for SRE Agent Lab
# Runs automatically after 'azd provision' via the postprovision hook
#
# Configures:
#   - srectl initialization
#   - Knowledge base upload (http-500-errors.md + grubify-architecture.md)
#   - Incident handler subagent
#   - Incident response plan
#   - (Optional) GitHub MCP connector + additional subagents if GITHUB_PAT is set
# =============================================================================
set -e

echo ""
echo "============================================="
echo "  SRE Agent Lab — Post-Provision Setup"
echo "============================================="
echo ""

# Get outputs from azd environment
AGENT_ENDPOINT=$(azd env get-values 2>/dev/null | grep "^SRE_AGENT_ENDPOINT=" | cut -d'=' -f2 | tr -d '"')
AGENT_NAME=$(azd env get-values 2>/dev/null | grep "^SRE_AGENT_NAME=" | cut -d'=' -f2 | tr -d '"')
RESOURCE_GROUP=$(azd env get-values 2>/dev/null | grep "^AZURE_RESOURCE_GROUP=" | cut -d'=' -f2 | tr -d '"')
CONTAINER_APP_URL=$(azd env get-values 2>/dev/null | grep "^CONTAINER_APP_URL=" | cut -d'=' -f2 | tr -d '"')
GITHUB_PAT_VALUE=$(azd env get-values 2>/dev/null | grep "^GITHUB_PAT=" | cut -d'=' -f2 | tr -d '"')

# Check GITHUB_PAT from env var if not in azd env
if [ -z "$GITHUB_PAT_VALUE" ] && [ -n "$GITHUB_PAT" ]; then
  GITHUB_PAT_VALUE="$GITHUB_PAT"
fi

echo "Agent Endpoint: ${AGENT_ENDPOINT}"
echo "Agent Name:     ${AGENT_NAME}"
echo "Resource Group: ${RESOURCE_GROUP}"
echo ""

# ---- Step 1: Initialize srectl ----
echo "Step 1/5: Initializing srectl..."
srectl init --resource-url "${AGENT_ENDPOINT}"
echo "  ✓ srectl initialized"
echo ""

# ---- Step 2: Upload knowledge base ----
echo "Step 2/5: Uploading knowledge base..."
srectl doc upload --file ./knowledge-base/http-500-errors.md
echo "  ✓ Uploaded http-500-errors.md"
srectl doc upload --file ./knowledge-base/grubify-architecture.md
echo "  ✓ Uploaded grubify-architecture.md"
echo ""

# ---- Step 3: Create incident handler subagent ----
echo "Step 3/5: Creating incident handler subagent..."
if [ -n "$GITHUB_PAT_VALUE" ]; then
  echo "  GitHub PAT detected — using full config (with GitHub tools)"
  srectl agent apply -f sre-config/agents/incident-handler-full.yaml
else
  echo "  No GitHub PAT — using core config (log analysis only)"
  srectl agent apply -f sre-config/agents/incident-handler-core.yaml
fi
echo "  ✓ incident-handler subagent created"
echo ""

# ---- Step 4: Create incident response plan ----
echo "Step 4/5: Creating incident response plan..."
srectl incidenthandler create \
  --id grubify-http-errors \
  --name "Grubify HTTP 500 Errors" \
  --priority 3 \
  --title-contains "500" \
  --handling-agent incident-handler \
  --max-attempts 3
echo "  ✓ Incident response plan created"
echo ""

# ---- Step 5: GitHub integration (optional) ----
if [ -n "$GITHUB_PAT_VALUE" ]; then
  echo "Step 5/5: Configuring GitHub integration..."

  # Configure GitHub MCP connector
  CONNECTOR_FILE=$(mktemp)
  sed "s|PLACEHOLDER_GITHUB_PAT|${GITHUB_PAT_VALUE}|g" \
    sre-config/connectors/github-mcp.yaml > "$CONNECTOR_FILE"
  srectl connector apply -f "$CONNECTOR_FILE"
  rm -f "$CONNECTOR_FILE"
  echo "  ✓ GitHub MCP connector configured"

  # Upload triage runbook
  srectl doc upload --file ./knowledge-base/github-issue-triage.md
  echo "  ✓ Uploaded github-issue-triage.md"

  # Create additional subagents
  srectl agent apply -f sre-config/agents/code-analyzer.yaml
  echo "  ✓ code-analyzer subagent created"

  srectl agent apply -f sre-config/agents/issue-triager.yaml
  echo "  ✓ issue-triager subagent created"

  echo ""
  echo "  GitHub integration: ✅ Configured"
else
  echo "Step 5/5: GitHub integration — ⏭️  Skipped (no PAT provided)"
  echo ""
  echo "  To add GitHub later, run:"
  echo "    export GITHUB_PAT=<your-pat>"
  echo "    ./scripts/setup-github.sh"
fi

echo ""
echo "============================================="
echo "  ✅ SRE Agent Lab Setup Complete!"
echo "============================================="
echo ""
echo "  SRE Agent Portal:  https://sre.azure.com"
echo "  Grubify App:       ${CONTAINER_APP_URL}"
echo "  Resource Group:    ${RESOURCE_GROUP}"
echo ""
echo "  Next steps:"
echo "    1. Open https://sre.azure.com and find your agent"
echo "    2. Explore Builder > Knowledge base, Connectors, Subagents"
echo "    3. Run ./scripts/break-app.sh to trigger an incident"
echo "    4. Watch the agent investigate and remediate!"
echo ""
