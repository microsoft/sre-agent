#!/bin/bash
# =============================================================================
# setup-github.sh — Add GitHub integration to an existing SRE Agent
# Uses REST APIs (az rest + curl) — no srectl dependency.
# For the srectl version, see setup-github-srectl.sh
#
# Usage:
#   export GITHUB_PAT=<your-github-pat>
#   ./scripts/setup-github.sh
# =============================================================================

# Windows compatibility: python3 may be 'python' on Windows
if command -v python3 &>/dev/null; then
  PYTHON=python3
elif command -v python &>/dev/null; then
  PYTHON=python
else
  echo "ERROR: Python not found"; exit 1
fi
set -e

if [ -z "$GITHUB_PAT" ]; then
  echo "❌ GITHUB_PAT is not set."
  echo ""
  echo "Usage:"
  echo "  export GITHUB_PAT=ghp_xxxxxxxxxxxx"
  echo "  ./scripts/setup-github.sh"
  echo ""
  echo ""
  echo "Recommended: Use a fine-grained PAT scoped to your grubify fork only:"
  echo "  1. Go to: https://github.com/settings/personal-access-tokens/new"
  echo "  2. Repository access → 'Only select repositories' → your grubify fork"
  echo "  3. Permissions: Contents:Read, Issues:Read+Write, Metadata:Read"
  echo ""
  echo "Alternative: Classic PAT with 'repo' scope (grants access to all repos)."
  exit 1
fi

# Read azd environment
AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
AGENT_NAME=$(azd env get-value SRE_AGENT_NAME 2>/dev/null || echo "")
RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")

if [ -z "$AGENT_ENDPOINT" ] || [ -z "$AGENT_NAME" ]; then
  echo "❌ Could not read agent details. Run from azd project directory after 'azd up'."
  exit 1
fi

AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

get_token() {
  az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>/dev/null
}

echo ""
echo "============================================="
echo "  🔗 Adding GitHub Integration"
echo "============================================="
echo ""

# Step 1: Upload triage runbook
echo "1️⃣  Uploading triage runbook..."
TOKEN=$(get_token)
curl -s -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "triggerIndexing=true" \
  -F "files=@./knowledge-base/github-issue-triage.md;type=text/plain" \
  > /dev/null 2>&1
echo "   ✅ Uploaded github-issue-triage.md"

# Step 2: Upgrade incident handler with GitHub tools
echo "2️⃣  Upgrading incident handler..."
SPEC_JSON=$($PYTHON -c "
import yaml, json
with open('sre-config/agents/incident-handler-full.yaml') as f:
    data = yaml.safe_load(f)
print(json.dumps(data['spec']))
")
SPEC_B64=$(echo -n "$SPEC_JSON" | base64)
az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/subagents/incident-handler?api-version=${API_VERSION}" \
  --body "{\"properties\":{\"value\":\"${SPEC_B64}\"}}" \
  --output none 2>/dev/null
echo "   ✅ incident-handler upgraded with GitHub tools"

# Step 3: Create code-analyzer subagent
echo "3️⃣  Creating code-analyzer subagent..."
SPEC_JSON=$($PYTHON -c "
import yaml, json
with open('sre-config/agents/code-analyzer.yaml') as f:
    data = yaml.safe_load(f)
print(json.dumps(data['spec']))
")
SPEC_B64=$(echo -n "$SPEC_JSON" | base64)
az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/subagents/code-analyzer?api-version=${API_VERSION}" \
  --body "{\"properties\":{\"value\":\"${SPEC_B64}\"}}" \
  --output none 2>/dev/null
echo "   ✅ code-analyzer created"

# Step 4: Create issue-triager subagent
echo "4️⃣  Creating issue-triager subagent..."
SPEC_JSON=$($PYTHON -c "
import yaml, json
with open('sre-config/agents/issue-triager.yaml') as f:
    data = yaml.safe_load(f)
print(json.dumps(data['spec']))
")
SPEC_B64=$(echo -n "$SPEC_JSON" | base64)
az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/subagents/issue-triager?api-version=${API_VERSION}" \
  --body "{\"properties\":{\"value\":\"${SPEC_B64}\"}}" \
  --output none 2>/dev/null
echo "   ✅ issue-triager created"

# Save PAT to azd env
azd env set GITHUB_PAT "$GITHUB_PAT" 2>/dev/null || true

echo ""
echo "============================================="
echo "  ✅ GitHub Integration Complete!"
echo "============================================="
echo ""
echo "  New capabilities:"
echo "  ├── incident-handler: now searches GitHub code + creates issues"
echo "  ├── code-analyzer: deep source code root cause analysis"
echo "  └── issue-triager: automated issue triage from runbook"
echo ""
