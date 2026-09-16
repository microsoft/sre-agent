#!/bin/bash
# =============================================================================
# post-provision.sh — Runs automatically after azd provision
#
# Configures the SRE Agent using dataplane REST APIs (no srectl dependency):
#   - Uploads knowledge sources
#   - Creates subagents via dataplane v2 API
#   - Creates incident response plan
#   - Configures GitHub OAuth, code access, and optional subagents
# =============================================================================
set -uo pipefail

# Windows compatibility: python3 may be 'python' on Windows
if command -v python3 &>/dev/null; then
  PYTHON=python3
elif command -v python &>/dev/null; then
  PYTHON=python
else
  echo "❌ ERROR: Python not found. Install Python 3."
  echo "   Windows: winget install Python.Python.3.12"
  echo "   Then disable App execution aliases for python.exe in Settings."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Temp directory — use script's own directory to avoid Windows path issues with curl
TEMP_DIR="${SCRIPT_DIR}/.tmp"
mkdir -p "$TEMP_DIR"

# Flags
SKIP_BUILD=""
RETRY_MODE=""
for arg in "$@"; do
  case "$arg" in
    --skip-build)  SKIP_BUILD="true" ;;
    --retry)       SKIP_BUILD="true"; RETRY_MODE="true" ;;
    --status)      STATUS_ONLY="true" ;;
    --build-only)  BUILD_ONLY="true" ;;
  esac
done

# ── Status-only mode: just show what's deployed ──────────────────────────────
if [ -n "${STATUS_ONLY:-}" ]; then
  AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
  RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")
  CONTAINER_APP_NAME=$(azd env get-value CONTAINER_APP_NAME 2>/dev/null || echo "")
  FRONTEND_APP_NAME=$(azd env get-value FRONTEND_APP_NAME 2>/dev/null || echo "")
  CONTAINER_APP_URL=$(azd env get-value CONTAINER_APP_URL 2>/dev/null || echo "")
  FRONTEND_URL=$(azd env get-value FRONTEND_APP_URL 2>/dev/null || echo "")
  if [ -z "$CONTAINER_APP_URL" ] || [ "$CONTAINER_APP_URL" = "https://" ]; then
    FQDN=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null | tr -d '\r')
    [ -n "$FQDN" ] && [ "$FQDN" != "None" ] && CONTAINER_APP_URL="https://${FQDN}"
  fi
  if [ -z "$FRONTEND_URL" ] || [ "$FRONTEND_URL" = "https://" ]; then
    FE_FQDN=$(az containerapp show --name "$FRONTEND_APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null | tr -d '\r')
    [ -n "$FE_FQDN" ] && [ "$FE_FQDN" != "None" ] && FRONTEND_URL="https://${FE_FQDN}"
  fi
  echo ""
  echo "============================================="
  echo "  SRE Agent Lab — Status"
  echo "============================================="
  echo ""
  echo "  🤖 Agent Portal:  https://sre.azure.com"
  echo "  📡 Agent API:     ${AGENT_ENDPOINT:-not set}"
  echo "  🌐 Grubify API:   ${CONTAINER_APP_URL:-not deployed}"
  echo "  🖥️  Grubify UI:    ${FRONTEND_URL:-not deployed}"
  echo "  📦 Resource Group: ${RESOURCE_GROUP:-not set}"
  echo ""
  echo "============================================="
  exit 0
fi

echo ""
echo "============================================="
echo "  SRE Agent Lab — Post-Provision Setup"
echo "============================================="
echo ""

# ── Read azd outputs ─────────────────────────────────────────────────────────
AGENT_ENDPOINT=$(azd env get-value SRE_AGENT_ENDPOINT 2>/dev/null || echo "")
AGENT_NAME=$(azd env get-value SRE_AGENT_NAME 2>/dev/null || echo "")
RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")
CONTAINER_APP_URL=$(azd env get-value CONTAINER_APP_URL 2>/dev/null || echo "")
CONTAINER_APP_NAME=$(azd env get-value CONTAINER_APP_NAME 2>/dev/null || echo "")
FRONTEND_APP_NAME=$(azd env get-value FRONTEND_APP_NAME 2>/dev/null || echo "")
ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
GITHUB_USER=$(azd env get-value GITHUB_USER 2>/dev/null || echo "")
if echo "$GITHUB_USER" | grep -q "ERROR\|not found"; then
  GITHUB_USER=""
fi
# Block using dm-chelupati repo — users must set their own GITHUB_USER
if [ "$GITHUB_USER" = "dm-chelupati" ]; then
  echo "⚠️  GITHUB_USER is set to dm-chelupati — please use your own GitHub account."
  echo "   Run: azd env set GITHUB_USER <your-github-username>"
  GITHUB_USER=""
fi
# Build the repo name from username
if [ -n "$GITHUB_USER" ]; then
  export GITHUB_REPO="${GITHUB_USER}/grubify"
else
  export GITHUB_REPO=""
fi

if [ -z "$AGENT_ENDPOINT" ] || [ -z "$AGENT_NAME" ]; then
  echo "❌ ERROR: Could not read agent details from azd environment."
  exit 1
fi

echo "📡 Agent: ${AGENT_ENDPOINT}"
echo "📦 RG:    ${RESOURCE_GROUP}"
echo ""

# ── Step 0: Build & deploy Grubify via ACR (cloud-side, no local clone needed) ─
GRUBIFY_REPO="https://github.com/dm-chelupati/grubify.git"

if [ -n "$SKIP_BUILD" ]; then
  echo "🐳 Step 0/5: ⏭️  Skipped (--skip-build or --retry)"
elif [ -n "$ACR_NAME" ]; then
  echo "🐳 Step 0/5: Building Grubify container images in ACR..."
  ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv 2>/dev/null)
  IMAGE_TAG="${ACR_LOGIN_SERVER}/grubify-api:latest"

  # Build from remote GitHub repo — no local clone needed
  echo "   Building API image from GitHub repo (this takes ~1-2 min)..."
  if [ -d "$PROJECT_DIR/src/grubify/GrubifyApi" ]; then
    # Use local source if submodule is cloned
    az acr build \
      --registry "$ACR_NAME" \
      --image "grubify-api:latest" \
      --file "$PROJECT_DIR/src/grubify/GrubifyApi/Dockerfile" \
      "$PROJECT_DIR/src/grubify/GrubifyApi" \
      --no-logs --output none 2>/dev/null
  else
    # Build directly from GitHub — no local clone needed
    az acr build \
      --registry "$ACR_NAME" \
      --image "grubify-api:latest" \
      --file "Dockerfile" \
      "${GRUBIFY_REPO}#main:GrubifyApi" \
      --no-logs --output none 2>/dev/null
  fi

  echo "   ✅ Built: ${IMAGE_TAG}"

  # Update the container app to use the new image
  echo "   Deploying API to container app..."
  az containerapp update \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "$IMAGE_TAG" \
    --output none 2>/dev/null

  # Refresh the app URL after update (retry if empty — Windows Git Bash can be slow)
  FQDN=""
  for i in 1 2 3; do
    FQDN=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null | tr -d '\r')
    if [ -n "$FQDN" ] && [ "$FQDN" != "None" ]; then
      break
    fi
    sleep 5
  done
  if [ -n "$FQDN" ] && [ "$FQDN" != "None" ]; then
    CONTAINER_APP_URL="https://${FQDN}"
  else
    CONTAINER_APP_URL=""
    echo "   ⚠️  Could not get API FQDN. Check Azure Portal for the URL."
  fi
  azd env set CONTAINER_APP_URL "$CONTAINER_APP_URL" 2>/dev/null || true

  echo "   ✅ API deployed: ${CONTAINER_APP_URL}"

  # Build and deploy frontend
  echo "   Building frontend image (this takes ~2-3 min)..."
  FRONTEND_IMAGE="${ACR_LOGIN_SERVER}/grubify-frontend:latest"
  if [ -d "$PROJECT_DIR/src/grubify/grubify-frontend" ]; then
    az acr build \
      --registry "$ACR_NAME" \
      --image "grubify-frontend:latest" \
      --file "$PROJECT_DIR/src/grubify/grubify-frontend/Dockerfile" \
      "$PROJECT_DIR/src/grubify/grubify-frontend" \
      --no-logs --output none 2>/dev/null
  else
    az acr build \
      --registry "$ACR_NAME" \
      --image "grubify-frontend:latest" \
      --file "Dockerfile" \
      "${GRUBIFY_REPO}#main:grubify-frontend" \
      --no-logs --output none 2>/dev/null
  fi

  echo "   ✅ Frontend built"
  echo "   Deploying frontend to container app..."
  az containerapp update \
    --name "$FRONTEND_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "$FRONTEND_IMAGE" \
    --set-env-vars "REACT_APP_API_BASE_URL=https://${CONTAINER_APP_URL#https://}/api" \
    --output none 2>/dev/null

  FE_FQDN=""
  for i in 1 2 3; do
    FE_FQDN=$(az containerapp show --name "$FRONTEND_APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null | tr -d '\r')
    if [ -n "$FE_FQDN" ] && [ "$FE_FQDN" != "None" ]; then
      break
    fi
    sleep 5
  done
  if [ -n "$FE_FQDN" ] && [ "$FE_FQDN" != "None" ]; then
    FRONTEND_URL="https://${FE_FQDN}"
  else
    FRONTEND_URL=""
    echo "   ⚠️  Could not get frontend FQDN. Check Azure Portal for the URL."
  fi
  azd env set FRONTEND_APP_URL "$FRONTEND_URL" 2>/dev/null || true

  echo "   ✅ Frontend deployed: ${FRONTEND_URL}"

  # Set CORS on the API to allow requests from the frontend
  if [ -n "$FRONTEND_URL" ]; then
    echo "   Configuring CORS on API..."
    az containerapp update \
      --name "$CONTAINER_APP_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --set-env-vars "AllowedOrigins__0=${FRONTEND_URL}" \
      --output none 2>/dev/null
    echo "   ✅ CORS configured"
  fi
else
  echo "   ⏭️  Skipped (ACR or source not found — using placeholder image)"
fi
echo ""

# Exit early if --build-only
if [ -n "${BUILD_ONLY:-}" ]; then
  echo "============================================="
  echo "  ✅ Build & Deploy Complete!"
  echo "============================================="
  echo ""
  echo "  🌐 Grubify API:   ${CONTAINER_APP_URL:-check Azure Portal}"
  echo "  🖥️  Grubify UI:    ${FRONTEND_URL:-check Azure Portal}"
  echo "============================================="
  exit 0
fi

# ── Helper: Get bearer token ─────────────────────────────────────────────────
get_token() {
  az account get-access-token --resource https://azuresre.dev --query accessToken -o tsv 2>/dev/null
}

# ── Helper: Create subagent via dataplane v2 API ─────────────────────────────
create_subagent() {
  local yaml_file="$1"
  local agent_name="$2"
  local token
  token=$(get_token)
  if [ -z "$token" ]; then
    echo "   ❌ ${agent_name}: could not acquire an SRE Agent data-plane token"
    return 1
  fi

  # Convert YAML spec to API JSON using helper script, pipe directly to curl
  local json_body
  json_body=$($PYTHON "$SCRIPT_DIR/yaml-to-api-json.py" "$yaml_file" "-" 2>&1)

  if [ -z "$json_body" ] || echo "$json_body" | grep -q "^Traceback\|ModuleNotFoundError\|ImportError\|SyntaxError"; then
    echo "   ❌ ${agent_name}: Python conversion failed"
    echo "   $json_body" | head -3
    return 1
  fi

  local http_code
  http_code=$(echo "$json_body" | curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/${agent_name}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d @-)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "202" ] || [ "$http_code" = "204" ]; then
    echo "   ✅ Created: ${agent_name}"
  else
    echo "   ❌ ${agent_name} returned HTTP ${http_code}"
    return 1
  fi
}

# ── Step 1: Upload knowledge sources ─────────────────────────────────────────
echo "📚 Step 1/5: Uploading knowledge sources..."
TOKEN=$(get_token)
if [ -z "$TOKEN" ]; then
  echo "   ❌ Could not acquire an SRE Agent data-plane token"
  exit 1
fi

KNOWLEDGE_FAILED=0
for f in ./knowledge-base/*.md; do
  file_name=$(basename "$f")
  connector_name=$(printf '%s' "$file_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g;s/--*/-/g;s/^-//;s/-$//')
  body=$($PYTHON - "$f" "$connector_name" <<'PY'
import base64
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
name = sys.argv[2]
print(json.dumps({
    "name": name,
    "type": "KnowledgeItem",
    "tags": [],
    "properties": {
        "dataConnectorType": "KnowledgeFile",
        "dataSource": name,
        "extendedProperties": {
            "displayName": path.name,
            "fileName": path.name,
            "fileContent": base64.b64encode(path.read_bytes()).decode("ascii"),
            "contentType": "text/markdown",
        },
    },
}))
PY
)
  HTTP_CODE=$(printf '%s' "$body" | curl -sS -o "${TEMP_DIR}/knowledge-response.txt" -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/${connector_name}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @-)
  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    echo "   ✅ ${file_name}"
  else
    echo "   ❌ ${file_name} returned HTTP ${HTTP_CODE}"
    KNOWLEDGE_FAILED=1
  fi
done
if [ "$KNOWLEDGE_FAILED" -ne 0 ]; then
  exit 1
fi
echo ""

# ── Step 2: Create incident-handler subagent ─────────────────────────────────
echo "🤖 Step 2/5: Creating/updating incident-handler subagent..."
if [ -n "$GITHUB_REPO" ]; then
  echo "   Using full config with GitHub tools"
  create_subagent "sre-config/agents/incident-handler-full.yaml" "incident-handler" || exit 1
else
  echo "   Using core config without GitHub tools"
  create_subagent "sre-config/agents/incident-handler-core.yaml" "incident-handler" || exit 1
fi
echo ""

# ── Step 3: Enable Azure Monitor + create response plan ──────────────────────
echo "🚨 Step 3/5: Enabling Azure Monitor incident platform..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

# Enable Azure Monitor as the incident platform (ARM PATCH)
  if az rest --method PATCH \
    --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
    --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"},"experimentalSettings":{"EnableWorkspaceTools":true,"EnableDevOpsTools":true,"EnablePythonTools":true}}}' \
    --output none 2>&1; then
    echo "   ✅ Azure Monitor enabled + DevOps & Python tools enabled"
  else
    echo "   ⚠️  Could not enable Azure Monitor"
  fi

  # Wait for Azure Monitor platform to initialize before creating the response plan
  echo "   Waiting for Azure Monitor to initialize..."
  sleep 30

# Create response plan with retry (Azure Monitor needs time to be ready)
FILTER_CREATED=false
for attempt in 1 2 3 4 5; do
  TOKEN=$(get_token)
  HTTP_CODE=$(curl -sS -o "${TEMP_DIR}/response-plan-resp.txt" -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/incidentFilters/grubify-http-errors" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary '{"name":"grubify-http-errors","type":"IncidentFilter","tags":[],"properties":{"incidentPlatform":"AzMonitor","priorities":["Sev0","Sev1","Sev2","Sev3","Sev4"],"titleContains":"alert-http-5xx-sre-lab","titleContainsAll":[],"titleContainsAny":[],"titleNotContains":[],"handlingAgent":"incident-handler","agentMode":"Autonomous","maxAutomatedInvestigationAttempts":3,"mergeEnabled":true,"mergeWindowHours":3,"isEnabled":true}}')

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "204" ]; then
    echo "   ✅ Response plan → incident-handler"
    FILTER_CREATED=true
    break
  else
    echo "   ⏳ Attempt $attempt/5: HTTP ${HTTP_CODE}, retrying in 15s..."
    sleep 15
  fi
done

  if [ "$FILTER_CREATED" = "false" ]; then
    echo "   ❌ Response plan failed after 5 attempts"
    echo "   API response: $(cat "${TEMP_DIR}/response-plan-resp.txt")"
    exit 1
  fi
  rm -f ${TEMP_DIR}/response-plan-resp.txt

echo ""

# ── Step 4: GitHub integration ───────────────────────────────────────────────
if [ -n "$GITHUB_REPO" ]; then
echo "🔗 Step 4/5: GitHub integration..."

# Check current GitHub OAuth domain state
TOKEN=$(get_token)
GITHUB_CONFIGURED=$(curl -sS "${AGENT_ENDPOINT}/api/v2/github/domains" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if len(d.get('values', [])) > 0 else 'false')
except: print('false')
" 2>/dev/null)

if [ "$GITHUB_CONFIGURED" != "true" ]; then
  OAUTH_URL=$(curl -sS "${AGENT_ENDPOINT}/api/v2/github/oauth/config" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('oAuthUrl', '') or d.get('OAuthUrl', '') or '')
except: print('')
" 2>/dev/null)

  if [ -z "$OAUTH_URL" ]; then
    echo "   ❌ Could not retrieve the GitHub OAuth URL"
    exit 1
  fi

  echo ""
  echo "   Open this URL and authorize GitHub access:"
  echo "   ${OAUTH_URL}"
  echo ""
  read -p "   Press Enter after authorization is complete..." _unused

  TOKEN=$(get_token)
  GITHUB_CONFIGURED=$(curl -sS "${AGENT_ENDPOINT}/api/v2/github/domains" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if len(d.get('values', [])) > 0 else 'false')
except: print('false')
" 2>/dev/null)
  if [ "$GITHUB_CONFIGURED" != "true" ]; then
    echo "   ❌ GitHub authorization was not detected"
    exit 1
  fi
fi
echo "   ✅ GitHub OAuth authorized"

# Add the repository after OAuth so the platform can validate access
echo "   Adding ${GITHUB_REPO} code repository..."
TOKEN=$(get_token)
REPO_NAME=$(echo "$GITHUB_REPO" | cut -d'/' -f2)
REPO_BODY=$($PYTHON -c "
import json
print(json.dumps({
    'name': '${REPO_NAME}',
    'type': 'CodeRepo',
    'properties': {
        'url': 'https://github.com/${GITHUB_REPO}',
        'type': 'GitHub',
        'description': 'Grubify application source for the starter lab',
    },
}))
")
REPO_CODE=$(printf '%s' "$REPO_BODY" | curl -sS -o "${TEMP_DIR}/repo-response.txt" -w "%{http_code}" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @-)
if [[ "$REPO_CODE" =~ ^2 ]]; then
  echo "   ✅ Code repo: ${GITHUB_REPO}"
else
  echo "   ❌ Code repo returned HTTP ${REPO_CODE}"
  cat "${TEMP_DIR}/repo-response.txt"
  exit 1
fi

# Create additional subagents
create_subagent "sre-config/agents/code-analyzer.yaml" "code-analyzer" || exit 1
create_subagent "sre-config/agents/issue-triager.yaml" "issue-triager" || exit 1

# Create scheduled task to triage issues every 12 hours
echo "   Creating scheduled task for issue triage..."
TOKEN=$(get_token)

TASK_BODY=$($PYTHON -c "
import json, os
repo = os.environ.get('GITHUB_REPO', 'dm-chelupati/grubify')
body = {'name':'triage-grubify-issues','type':'ScheduledTask','tags':[],'properties':{'name':'triage-grubify-issues','description':'Triage customer issues in '+repo+' every 12 hours','cronExpression':'0 */12 * * *','agentPrompt':'Use the issue-triager subagent to list all open issues in '+repo+' that have [Customer Issue] in the title and have not been triaged yet. For each untriaged customer issue, classify it, add labels, and post a triage comment following the triage runbook in the knowledge base.','agent':'issue-triager','agentMode':'Autonomous','isEnabled':True}}
print(json.dumps(body))
")
HTTP_CODE=$(echo "$TASK_BODY" | curl -sS -o "${TEMP_DIR}/scheduled-task-response.txt" -w "%{http_code}" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/scheduledtasks/triage-grubify-issues" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d @-)
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
  echo "   ✅ Scheduled task: triage-grubify-issues (every 12h → issue-triager)"
else
  echo "   ❌ Scheduled task returned HTTP ${HTTP_CODE}"
  cat "${TEMP_DIR}/scheduled-task-response.txt"
  exit 1
fi

echo ""
echo "   GitHub integration: ✅ Configured"

# Create sample customer issues on the user's fork
echo "   Creating sample customer issues..."
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  bash "$SCRIPT_DIR/create-sample-issues.sh" "$GITHUB_REPO" 2>/dev/null || echo "   ⚠️  Could not create sample issues (gh auth may need 'repo' scope)"
else
  echo "   ⚠️  gh CLI not authenticated — run 'gh auth login' then 'bash scripts/create-sample-issues.sh ${GITHUB_REPO}'"
fi

else
  echo "🔗 Step 4/5: GitHub integration... ⏭️  Skipped"
  echo "   No GITHUB_USER set. To enable GitHub integration:"
  echo "   1. Fork https://github.com/dm-chelupati/grubify"
  echo "      (Enable Issues: Settings → Features → Issues ✅)"
  echo "   2. Run: azd env set GITHUB_USER <your-github-username>"
  echo "   3. Re-run: bash scripts/post-provision.sh --retry"
  echo ""
fi

# ── Verification: Show what was set up ────────────────────────────────────────
echo ""
echo "============================================="
echo "  📋 Verifying what was provisioned..."
echo "============================================="
echo ""
TOKEN=$(get_token)

# Knowledge sources
echo "  📚 Knowledge Sources:"
KNOWLEDGE_SOURCES=$(curl -sS "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
echo "$KNOWLEDGE_SOURCES" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
  items=d.get('value', d if isinstance(d, list) else [])
  knowledge=[item for item in items if item.get('properties',{}).get('dataConnectorType','').startswith('Knowledge')]
  for item in knowledge: print(f'     ✅ {item.get("name", "?")}')
  if not knowledge: print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

# Subagents
echo "  🤖 Subagents:"
AGENTS=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
echo "$AGENTS" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('value',[]):
        tools=a.get('properties',{}).get('tools',[]) or []
        mcp=a.get('properties',{}).get('mcpTools',[]) or []
        all_tools=tools+mcp
        print(f'     ✅ {a[\"name\"]} ({len(all_tools)} tools)')
    if not d.get('value'): print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

# GitHub and code repositories
echo "  🔗 GitHub and Code Repositories:"
GITHUB_DOMAINS=$(curl -sS "${AGENT_ENDPOINT}/api/v2/github/domains" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo '{}')
REPOSITORIES=$(curl -sS "${AGENT_ENDPOINT}/api/v2/repos" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo '{}')
echo "$GITHUB_DOMAINS" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
  domains=d.get('values', [])
  print('     ✅ GitHub OAuth' if domains else '     (GitHub OAuth not configured)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo "$REPOSITORIES" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    repos=d.get('value', d if isinstance(d, list) else [])
    for repo in repos: print(f'     ✅ {repo.get("name", "?")}')
    if not repos: print('     (no code repositories)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

# Response plans
echo "  🚨 Response Plans:"
FILTERS=$(curl -sS "${AGENT_ENDPOINT}/api/v2/extendedAgent/incidentFilters" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
echo "$FILTERS" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
  filters=d.get('value', d if isinstance(d, list) else [])
  for f in filters:
    agent=f.get('properties',{}).get('handlingAgent','(none)')
    name=f.get('name','?')
        print(f'     ✅ {name} → subagent: {agent}')
  if not filters: print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

# Incident platform
echo "  📡 Incident Platform:"
PLATFORM_TYPE=$(az rest --method GET --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" --query 'properties.incidentManagementConfiguration.type' -o tsv 2>/dev/null || echo "")
if [ "$PLATFORM_TYPE" = "AzMonitor" ]; then
  echo "     ✅ Azure Monitor"
else
  echo "     ❌ ${PLATFORM_TYPE:-Not configured}"
fi
echo ""

# Scheduled tasks
echo "  ⏰ Scheduled Tasks:"
TASKS=$(curl -sS "${AGENT_ENDPOINT}/api/v2/extendedAgent/scheduledtasks" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "{}")
echo "$TASKS" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    tasks=d.get('value', d if isinstance(d, list) else [])
    for task in tasks:
        props=task.get('properties',{})
        print(f'     ✅ {task.get("name", "?")} ({props.get("cronExpression", "?")})')
    if not tasks: print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

# Required-state gate: setup must not report success with missing components.
VERIFY_FAILURES=0
KNOWLEDGE_COUNT=$(echo "$KNOWLEDGE_SOURCES" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); items=d.get('value', d if isinstance(d,list) else []); print(len([x for x in items if x.get('properties',{}).get('dataConnectorType','').startswith('Knowledge')]))" 2>/dev/null || echo 0)
INCIDENT_HANDLER_COUNT=$(echo "$AGENTS" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); print(len([x for x in d.get('value',[]) if x.get('name')=='incident-handler']))" 2>/dev/null || echo 0)
RESPONSE_PLAN_COUNT=$(echo "$FILTERS" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); items=d.get('value', d if isinstance(d,list) else []); print(len([x for x in items if x.get('name')=='grubify-http-errors']))" 2>/dev/null || echo 0)

[ "$KNOWLEDGE_COUNT" -ge 4 ] || { echo "   ❌ Expected 4 knowledge sources, found $KNOWLEDGE_COUNT"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
[ "$INCIDENT_HANDLER_COUNT" -eq 1 ] || { echo "   ❌ incident-handler is missing"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
[ "$RESPONSE_PLAN_COUNT" -eq 1 ] || { echo "   ❌ grubify-http-errors response plan is missing"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
[ "$PLATFORM_TYPE" = "AzMonitor" ] || { echo "   ❌ Azure Monitor incident platform is not connected"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }

if [ -n "$GITHUB_REPO" ]; then
  REPO_NAME=$(echo "$GITHUB_REPO" | cut -d'/' -f2)
  REPO_COUNT=$(echo "$REPOSITORIES" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); items=d.get('value', d if isinstance(d,list) else []); print(len([x for x in items if x.get('name')=='${REPO_NAME}']))" 2>/dev/null || echo 0)
  GITHUB_AGENT_COUNT=$(echo "$AGENTS" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); names={x.get('name') for x in d.get('value',[])}; print(1 if {'code-analyzer','issue-triager'} <= names else 0)" 2>/dev/null || echo 0)
  TASK_COUNT=$(echo "$TASKS" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); items=d.get('value', d if isinstance(d,list) else []); print(len([x for x in items if x.get('name')=='triage-grubify-issues']))" 2>/dev/null || echo 0)
  [ "$GITHUB_CONFIGURED" = "true" ] || { echo "   ❌ GitHub OAuth is not configured"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
  [ "$REPO_COUNT" -eq 1 ] || { echo "   ❌ ${REPO_NAME} code repository is missing"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
  [ "$GITHUB_AGENT_COUNT" -eq 1 ] || { echo "   ❌ GitHub subagents are missing"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
  [ "$TASK_COUNT" -eq 1 ] || { echo "   ❌ triage-grubify-issues scheduled task is missing"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }
fi

if [ "$VERIFY_FAILURES" -gt 0 ]; then
  echo ""
  echo "❌ Agent configuration verification failed with ${VERIFY_FAILURES} missing component(s)."
  rm -rf "$TEMP_DIR"
  exit 1
fi

# ── Summary ──────────────────────────────────────────────────────────────────
# Always refresh URLs from Azure
if [ -z "$CONTAINER_APP_URL" ] || [ "$CONTAINER_APP_URL" = "https://" ]; then
  FQDN=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null | tr -d '\r')
  [ -n "$FQDN" ] && [ "$FQDN" != "None" ] && CONTAINER_APP_URL="https://${FQDN}"
fi
if [ -z "${FRONTEND_URL:-}" ] || [ "${FRONTEND_URL:-}" = "https://" ]; then
  FE_FQDN=$(az containerapp show --name "$FRONTEND_APP_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null | tr -d '\r')
  [ -n "$FE_FQDN" ] && [ "$FE_FQDN" != "None" ] && FRONTEND_URL="https://${FE_FQDN}"
fi

echo "============================================="
echo "  ✅ SRE Agent Lab Setup Complete!"
echo "============================================="
echo ""
echo "  🤖 Agent Portal:  https://sre.azure.com"
echo "  📡 Agent API:     ${AGENT_ENDPOINT}"
echo "  🌐 Grubify API:   ${CONTAINER_APP_URL:-not deployed}"
echo "  🖥️  Grubify UI:    ${FRONTEND_URL:-not deployed}"
echo "  📦 Resource Group: ${RESOURCE_GROUP}"
echo ""
echo "  👉 Go to https://sre.azure.com and explore:"
echo "     1. Knowledge sources (see uploaded runbooks + code repo)"
echo "     2. Builder → Custom agents (see subagents + tools)"
echo "     3. Builder → Connectors (see GitHub OAuth)"
echo "     4. Builder → Scheduled tasks (see triage-grubify-issues)"
echo "     5. Settings → Incident platform (Azure Monitor)"
echo ""
echo "  Then run: ./scripts/break-app.sh"
echo "============================================="

# Cleanup temp directory
rm -rf "$TEMP_DIR"
