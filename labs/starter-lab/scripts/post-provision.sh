#!/bin/bash
# =============================================================================
# post-provision.sh — Runs automatically after azd provision
#
# Configures the SRE Agent using dataplane REST APIs (no srectl dependency):
#   - Uploads knowledge base files
#   - Creates subagents via dataplane v2 API
#   - Creates incident response plan
#   - GitHub OAuth connector + subagents
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

# Temp directory — use script's own directory to avoid Windows path issues with curl
TEMP_DIR="${SCRIPT_DIR}/.tmp"
mkdir -p "$TEMP_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

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
# Build the repo name from username (defaults to dm-chelupati if not set)
export GITHUB_REPO="${GITHUB_USER:+${GITHUB_USER}/grubify}"
GITHUB_REPO="${GITHUB_REPO:-dm-chelupati/grubify}"
export GITHUB_REPO

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

  # Convert YAML spec to API JSON using helper script
  $PYTHON "$SCRIPT_DIR/yaml-to-api-json.py" "$yaml_file" "${TEMP_DIR}/${agent_name}-body.json" > /dev/null 2>&1

  local http_code
  http_code=$(curl -s -o ${TEMP_DIR}/${agent_name}-resp.txt -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/${agent_name}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data-binary @"${TEMP_DIR}/${agent_name}-body.json")

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "202" ] || [ "$http_code" = "204" ]; then
    echo "   ✅ Created: ${agent_name}"
  else
    echo "   ⚠️  ${agent_name} returned HTTP ${http_code}"
    cat "${TEMP_DIR}/${agent_name}-resp.txt" 2>/dev/null | head -3
  fi
  rm -f "${TEMP_DIR}/${agent_name}-body.json" "${TEMP_DIR}/${agent_name}-resp.txt"
}

# ── Helper: Check if something exists (for --retry mode) ─────────────────────
check_kb_files() {
  local token=$(get_token)
  local count=$(curl -s "${AGENT_ENDPOINT}/api/v1/AgentMemory/files" -H "Authorization: Bearer ${token}" 2>/dev/null | $PYTHON -c "import sys,json; print(len(json.load(sys.stdin).get('files',[])))" 2>/dev/null || echo "0")
  [ "$count" -ge 2 ]
}

check_subagent_exists() {
  local name="$1"
  local token=$(get_token)
  local code=$(curl -s -o /dev/null -w "%{http_code}" "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/${name}" -H "Authorization: Bearer ${token}" 2>/dev/null)
  [ "$code" = "200" ]
}

check_response_plan_exists() {
  local token=$(get_token)
  local count=$(curl -s "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters" -H "Authorization: Bearer ${token}" 2>/dev/null | $PYTHON -c "import sys,json; d=json.load(sys.stdin); print(len([f for f in d if f.get('handlingAgent')]))" 2>/dev/null || echo "0")
  [ "$count" -ge 1 ]
}

check_connector_exists() {
  local count=$(az rest --method GET --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors?api-version=${API_VERSION}" --query "length(value)" -o tsv 2>/dev/null || echo "0")
  [ "$count" -ge 1 ]
}

# ── Step 1: Upload knowledge base files ──────────────────────────────────────
echo "📚 Step 1/5: Uploading knowledge base..."
TOKEN=$(get_token)

# Build curl args array dynamically from knowledge-base/ directory
CURL_ARGS=(-s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "triggerIndexing=true")
KB_NAMES=""
for f in ./knowledge-base/*.md; do
  CURL_ARGS+=(-F "files=@${f};type=text/plain")
  KB_NAMES="${KB_NAMES} $(basename "$f")"
done

HTTP_CODE=$(curl "${CURL_ARGS[@]}")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo "   ✅ Uploaded:${KB_NAMES}"
else
  echo "   ⚠️  Upload returned HTTP ${HTTP_CODE}"
fi
echo ""

# ── Step 2: Create incident-handler subagent ─────────────────────────────────
echo "🤖 Step 2/5: Creating/updating incident-handler subagent..."
echo "   Using full config with GitHub tools"
create_subagent "sre-config/agents/incident-handler-full.yaml" "incident-handler"
echo ""

# ── Step 3: Enable Azure Monitor + create response plan ──────────────────────
echo "🚨 Step 3/5: Enabling Azure Monitor incident platform..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null)
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

# Enable Azure Monitor as the incident platform (ARM PATCH)
  if az rest --method PATCH \
    --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
    --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"}}}' \
    --output none 2>&1; then
    echo "   ✅ Azure Monitor enabled"
  else
    echo "   ⚠️  Could not enable Azure Monitor"
  fi

  # Wait for Azure Monitor platform to initialize before creating filters
  echo "   Waiting for Azure Monitor to initialize..."
  sleep 30

  # Delete any existing filters (previous runs)
  TOKEN=$(get_token)
  curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/grubify-http-errors" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

# Create response plan with retry (Azure Monitor needs time to be ready)
FILTER_CREATED=false
for attempt in 1 2 3 4 5; do
  TOKEN=$(get_token)
  HTTP_CODE=$(curl -s -o ${TEMP_DIR}/response-plan-resp.txt -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/grubify-http-errors" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary '{"id":"grubify-http-errors","name":"Grubify HTTP Errors","priorities":["Sev0","Sev1","Sev2","Sev3","Sev4"],"titleContains":"","handlingAgent":"incident-handler","agentMode":"autonomous","maxAttempts":3}')

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "409" ]; then
    echo "   ✅ Response plan → incident-handler"
    FILTER_CREATED=true
    break
  else
    echo "   ⏳ Attempt $attempt/5: HTTP ${HTTP_CODE}, retrying in 15s..."
    sleep 15
  fi
done

  if [ "$FILTER_CREATED" = "false" ]; then
    echo "   ⚠️  Response plan failed after 5 attempts (set up in portal or run: ./scripts/post-provision.sh --retry)"
  fi
  rm -f ${TEMP_DIR}/response-plan-resp.txt

# Always delete the default quickstart handler (auto-created by Azure Monitor platform)
TOKEN=$(get_token)
curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_response_plan" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

echo ""

# ── Step 4: GitHub integration ───────────────────────────────────────────────
echo "🔗 Step 4/5: GitHub integration..."

# Create GitHub OAuth connector via data plane API (no PAT needed)
echo "   Creating GitHub OAuth connector..."
TOKEN=$(get_token)
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/github" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"github","type":"AgentConnector","properties":{"dataConnectorType":"GitHubOAuth","dataSource":"github-oauth"}}')
if [ "$RESULT" = "200" ] || [ "$RESULT" = "201" ]; then
  echo "   ✅ GitHub OAuth connector created"
else
  echo "   ⚠️  GitHub connector returned HTTP ${RESULT}"
fi

# Get OAuth login URL for user to authorize
TOKEN=$(get_token)
OAUTH_URL=$(curl -s "${AGENT_ENDPOINT}/api/v1/github/config" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | $PYTHON -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('oAuthUrl', '') or d.get('OAuthUrl', '') or '')
except: print('')
" 2>/dev/null)

# Create GitHub OAuth connector via ARM (needed for OAuth flow to fully work)
echo "   Creating GitHub OAuth connector via ARM..."
TOKEN=$(get_token)
ARM_RESULT=$(az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
  --body '{"properties":{"dataConnectorType":"GitHubOAuth","dataSource":"github-oauth"}}' \
  -o none 2>&1 || true)
echo "   ✅ GitHub OAuth connector (ARM)"

# Upload triage runbook
TOKEN=$(get_token)
curl -s -o /dev/null \
  -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "triggerIndexing=true" \
  -F "files=@./knowledge-base/github-issue-triage.md;type=text/plain"
echo "   ✅ Uploaded: github-issue-triage.md"

# Create additional subagents
create_subagent "sre-config/agents/code-analyzer.yaml" "code-analyzer"
create_subagent "sre-config/agents/issue-triager.yaml" "issue-triager"

# Create scheduled task to triage issues every 12 hours
echo "   Creating scheduled task for issue triage..."
TOKEN=$(get_token)

EXISTING_TASKS=$(curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "[]")
echo "$EXISTING_TASKS" | $PYTHON -c "
import sys,json
try:
    tasks=json.load(sys.stdin)
    for t in tasks:
        if t.get('name')=='triage-grubify-issues':
            print(t.get('id',''))
except: pass
" 2>/dev/null | while read -r task_id; do
    if [ -n "$task_id" ]; then
      curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/scheduledtasks/${task_id}" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null
    fi
  done

$PYTHON -c "
import json, os
repo = os.environ.get('GITHUB_REPO', 'dm-chelupati/grubify')
body = {'name':'triage-grubify-issues','description':f'Triage customer issues in {repo} every 12 hours','cronExpression':'0 */12 * * *','agentPrompt':f'Use the issue-triager subagent to list all open issues in {repo} that have [Customer Issue] in the title and have not been triaged yet. For each untriaged customer issue, classify it, add labels, and post a triage comment following the triage runbook in the knowledge base.','agent':'issue-triager'}
with open('${TEMP_DIR}/scheduled-task-body.json', 'w') as f: json.dump(body, f)
"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @${TEMP_DIR}/scheduled-task-body.json)
rm -f ${TEMP_DIR}/scheduled-task-body.json
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
  echo "   ✅ Scheduled task: triage-grubify-issues (every 12h → issue-triager)"
else
  echo "   ⚠️  Scheduled task returned HTTP ${HTTP_CODE}"
fi

echo ""
echo "   GitHub integration: ✅ Configured"

if [ -n "$OAUTH_URL" ]; then
  echo ""
  echo "   ┌──────────────────────────────────────────────────────────┐"
  echo "   │  Sign in to GitHub to authorize the SRE Agent:          │"
  echo "   │  ${OAUTH_URL}"
  echo "   │  Open this URL in your browser and click 'Authorize'    │"
  echo "   └──────────────────────────────────────────────────────────┘"
  echo ""
  read -p "   Press Enter after you have authorized in the browser..." _unused
fi

# Add code repo AFTER OAuth so the token is active
echo "   Adding ${GITHUB_REPO} code repository..."
TOKEN=$(get_token)
REPO_NAME=$(echo "$GITHUB_REPO" | cut -d'/' -f2)
curl -s -o /dev/null -w "" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"type\":\"CodeRepo\",\"properties\":{\"url\":\"https://github.com/${GITHUB_REPO}\",\"authConnectorName\":\"github\"}}"
echo "   ✅ Code repo: ${GITHUB_REPO}"
echo ""

# ── Verification: Show what was set up ────────────────────────────────────────
echo ""
echo "============================================="
echo "  📋 Verifying what was provisioned..."
echo "============================================="
echo ""
TOKEN=$(get_token)

# KB files
echo "  📚 Knowledge Base:"
KB_FILES=$(curl -s "${AGENT_ENDPOINT}/api/v1/AgentMemory/files" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
echo "$KB_FILES" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for f in d.get('files',[]):
        status='✅' if f.get('isIndexed') else '⏳'
        print(f'     {status} {f[\"name\"]}')
    if not d.get('files'): print('     (none)')
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

# Connectors
echo "  🔗 Connectors:"
CONNECTORS=$(az rest --method GET --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors?api-version=${API_VERSION}" --query "value[].{name:name,state:properties.provisioningState}" -o json 2>/dev/null || echo "[]")
echo "$CONNECTORS" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for c in d:
        state='✅' if c.get('state')=='Succeeded' else '⏳ '+str(c.get('state',''))
        print(f'     {state} {c[\"name\"]}')
    if not d: print('     (none — connector pending)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

# Response plans
echo "  🚨 Response Plans:"
FILTERS=$(curl -s "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
echo "$FILTERS" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for f in d:
        agent=f.get('handlingAgent','(none)')
        name=f.get('id','?')
        print(f'     ✅ {name} → subagent: {agent}')
    if not d: print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

# Incident platform
echo "  📡 Incident Platform:"
PLATFORM_RAW=$(curl -s "${AGENT_ENDPOINT}/api/v1/incidentPlayground/incidentPlatformType" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "{}")
echo "$PLATFORM_RAW" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    ptype = d.get('incidentPlatformType', 'Unknown') if isinstance(d, dict) else str(d)
    icon = '✅' if ptype == 'AzMonitor' else '⚠️'
    display = {'AzMonitor': 'Azure Monitor', 'None': 'Not configured'}.get(ptype, ptype)
    print(f'     {icon} {display}')
except: print('     ⚠️  Could not determine')
" 2>/dev/null
echo ""

# Scheduled tasks
echo "  ⏰ Scheduled Tasks:"
TASKS=$(curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "[]")
echo "$TASKS" | $PYTHON -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for t in d:
        name=t.get('name','?')
        cron=t.get('cronExpression','?')
        agent=t.get('agent','(none)')
        status=t.get('status','?')
        icon='✅' if status=='Active' else '⏸️'
        print(f'     {icon} {name} ({cron}) → {agent}')
    if not d: print('     (none)')
except: print('     (could not retrieve)')
" 2>/dev/null
echo ""

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
