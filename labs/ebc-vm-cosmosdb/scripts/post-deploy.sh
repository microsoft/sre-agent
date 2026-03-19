#!/bin/bash
# ============================================================
# Post-deployment setup script for Lab 1
# Run after `azd provision` to configure:
#   1. Activity Log diagnostic settings
#   2. SRE Agent Administrator role
#   3. Azure Monitor as incident platform
#   4. VM Performance Diagnostics skill
#   5. Compliance Drift Detection skill
#   6. VM Remediation Approval hook
#   7. Compliance Drift Scan scheduled task
# ============================================================

set -uo pipefail

# Windows compatibility: python3 may be 'python' on Windows
if command -v python3 &>/dev/null; then
  PYTHON=python3
elif command -v python &>/dev/null; then
  PYTHON=python
else
  echo "ERROR: Python not found. Install Python 3."
  exit 1
fi

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Flags
SKIP_APP_INSTALL=""
for arg in "$@"; do
  case "$arg" in
    --retry) SKIP_APP_INSTALL="true" ;;
  esac
done

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Lab 1: VM Performance + Drift — Post-Deployment Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# ---- Resolve resource names ----
echo -e "\n${YELLOW}[1/7] Resolving deployed resources...${NC}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [[ -z "$RESOURCE_GROUP" ]]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "vm-perf-demo")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Get SRE Agent endpoint
AGENT_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv 2>/dev/null)
AGENT_ENDPOINT=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" \
  --name "$AGENT_NAME" \
  --query "properties.agentEndpoint" -o tsv 2>/dev/null || echo "")

if [[ -z "$AGENT_ENDPOINT" ]]; then
  echo -e "${RED}ERROR: Could not find SRE Agent endpoint. Check resource group: $RESOURCE_GROUP${NC}"
  exit 1
fi

# Get LAW resource ID
LAW_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.OperationalInsights/workspaces" \
  --query "[0].id" -o tsv 2>/dev/null)
LAW_NAME=$(az resource show --ids "$LAW_ID" --query "name" -o tsv 2>/dev/null || echo "")

AGENT_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" --query "[0].id" -o tsv 2>/dev/null)

echo -e "${GREEN}  Resource Group: $RESOURCE_GROUP${NC}"
echo -e "${GREEN}  Agent Endpoint: $AGENT_ENDPOINT${NC}"
echo -e "${GREEN}  LAW Name: $LAW_NAME${NC}"
echo -e "${GREEN}  Agent: $AGENT_NAME${NC}"

# ---- Get Cosmos DB + VM info ----
VM_APP_NAME=$(az vm list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")
COSMOS_ENDPOINT=$(azd env get-value COSMOS_ENDPOINT 2>/dev/null || echo "")
COSMOS_DB_NAME=$(azd env get-value COSMOS_DB_NAME 2>/dev/null || echo "ecommerce")

echo -e "${GREEN}  VM App: $VM_APP_NAME${NC}"
echo -e "${GREEN}  Cosmos DB: $COSMOS_ENDPOINT${NC}"

# ---- Step 1.5: Install web app on VM ----
if [[ -n "$SKIP_APP_INSTALL" ]]; then
  echo -e "\n${YELLOW}[1.5/7] App install: ⏭️  Skipped (--retry)${NC}"
elif [[ -n "$VM_APP_NAME" && -n "$COSMOS_ENDPOINT" ]]; then
  echo -e "\n${YELLOW}[1.5/7] Installing E-Commerce app on VM...${NC}"

  # Step 1: Install Node.js + dependencies
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_APP_NAME" \
    --command-id RunShellScript \
    --scripts "
      set -e
      if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
      fi
      mkdir -p /opt/ecommerce
      cd /opt/ecommerce
      cat > package.json << 'PKGEOF'
{\"name\":\"ecommerce-api\",\"version\":\"1.0.0\",\"dependencies\":{\"express\":\"^4.18.2\",\"@azure/cosmos":"^4.0.0","@azure/identity":"^4.0.0\"}}
PKGEOF
      npm install --production 2>/dev/null
      cat > /etc/systemd/system/ecommerce.service << SVCEOF
[Unit]
Description=E-Commerce API
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/ecommerce
Environment=PORT=80
Environment=COSMOS_ENDPOINT=${COSMOS_ENDPOINT}
Environment=COSMOS_DB_NAME=${COSMOS_DB_NAME}
ExecStart=/usr/bin/node app.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVCEOF
      systemctl daemon-reload
      systemctl enable ecommerce
      echo 'Dependencies installed'
    " --output none 2>/dev/null && \
    echo -e "${GREEN}  ✓ Node.js + deps installed${NC}" || \
    echo -e "${YELLOW}  ⚠️  Install failed (VM extensions may still be provisioning — wait and retry)${NC}"

  # Step 2: Deploy app.js via base64 (avoids quoting issues)
  echo "   Deploying app.js..."
  APP_B64=$(base64 < "$LAB_DIR/src/app.js")
  az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_APP_NAME" \
    --command-id RunShellScript \
    --scripts "echo '${APP_B64}' | base64 -d > /opt/ecommerce/app.js && systemctl restart ecommerce && sleep 3 && curl -s http://localhost/api/health 2>&1 || echo 'app starting'" \
    --query "value[0].message" -o tsv 2>/dev/null
  echo -e "${GREEN}  ✓ App deployed and started${NC}"

  # Show VM IP
  VM_IP=$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" --name "$VM_APP_NAME" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>/dev/null || echo "")
  if [[ -n "$VM_IP" ]]; then
    echo -e "${GREEN}  ✓ App URL: http://${VM_IP}${NC}"
  fi
else
  echo -e "\n${YELLOW}[1.5/7] Skipping app install (VM: ${VM_APP_NAME:-missing}, Cosmos: ${COSMOS_ENDPOINT:-missing})${NC}"
fi

# ---- Helper: Get auth token ----
get_agent_token() {
  az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null
}

# ---- Helper: Call ExtendedAgent API ----
agent_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local token
  token=$(get_agent_token)

  if [[ -n "$body" ]]; then
    curl -s -X "$method" \
      "${AGENT_ENDPOINT}${path}" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -s -X "$method" \
      "${AGENT_ENDPOINT}${path}" \
      -H "Authorization: Bearer $token"
  fi
}

# ---- Step 2: SRE Agent Administrator role ----
echo -e "\n${YELLOW}[2/7] Ensuring SRE Agent Administrator role...${NC}"
ACCESS_TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null)
USER_OID=""
if [[ -n "$ACCESS_TOKEN" ]]; then
  USER_OID=$($PYTHON -c "
import json, base64, sys
try:
    token = sys.argv[1]
    payload = token.split('.')[1]
    payload += '=' * (4 - len(payload) % 4)
    claims = json.loads(base64.b64decode(payload))
    print(claims.get('oid', ''))
except Exception:
    pass
" "$ACCESS_TOKEN")
fi

if [[ -n "$USER_OID" && -n "$AGENT_ID" ]]; then
  az role assignment create \
    --assignee-object-id "$USER_OID" \
    --assignee-principal-type User \
    --role "SRE Agent Administrator" \
    --scope "$AGENT_ID" \
    --output none 2>/dev/null || true
  echo -e "${GREEN}  ✓ SRE Agent Administrator role assigned.${NC}"
fi

# ---- Step 3: Activity Log diagnostic settings ----
echo -e "\n${YELLOW}[3/7] Configuring Activity Log diagnostic settings...${NC}"
EXISTING=$(az monitor diagnostic-settings subscription list \
  --query "[?name=='activity-to-law'].name" -o tsv 2>/dev/null || echo "")

if [[ -z "$EXISTING" ]]; then
  az monitor diagnostic-settings subscription create \
    --name "activity-to-law" \
    --workspace "$LAW_ID" \
    --logs '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true}]' \
    --output none 2>/dev/null && \
    echo -e "${GREEN}  ✓ Diagnostic settings configured.${NC}" || \
    echo -e "${YELLOW}  Could not create diagnostic settings.${NC}"
else
  echo -e "${GREEN}  Diagnostic settings already exist. Skipping.${NC}"
fi

# ---- Step 4: Configure Azure Monitor as incident platform ----
echo -e "\n${YELLOW}[4/7] Configuring Azure Monitor as incident platform...${NC}"
API_VERSION="2025-05-01-preview"
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"

az rest --method patch \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  --body '{
    "properties": {
      "incidentManagementConfiguration": {
        "type": "AzMonitor",
        "connectionName": "azmonitor"
      },
      "experimentalSettings": {
        "EnableWorkspaceTools": true,
        "EnableDevOpsTools": true,
        "EnablePythonTools": true
      }
    }
  }' --output none 2>/dev/null && \
  echo -e "${GREEN}  ✓ Azure Monitor + DevOps & Python tools configured.${NC}" || \
  echo -e "${YELLOW}  Could not configure incident platform.${NC}"

# ---- Step 5: Upload knowledge base (skill docs as KB files) ----
echo -e "\n${YELLOW}[5/7] Uploading knowledge base...${NC}"
TOKEN=$(get_agent_token)

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "triggerIndexing=true" \
  -F "files=@${LAB_DIR}/skills/vm-performance-diagnostics.md;type=text/plain" \
  -F "files=@${LAB_DIR}/skills/compliance-drift-detection.md;type=text/plain")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo -e "${GREEN}  ✓ Uploaded: vm-performance-diagnostics.md${NC}"
  echo -e "${GREEN}  ✓ Uploaded: compliance-drift-detection.md${NC}"
else
  echo -e "${YELLOW}  Upload returned HTTP ${HTTP_CODE}${NC}"
fi

# ---- Step 5.5: GitHub connector + code repo ----
echo -e "\n${YELLOW}[5.5/7] Configuring GitHub connector + code repo...${NC}"
GITHUB_REPO="dm-chelupati/ecommerce"

# Create GitHub OAuth connector (dataplane)
TOKEN=$(get_agent_token)
curl -s -o /dev/null -w "" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/github" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"github","type":"AgentConnector","properties":{"dataConnectorType":"GitHubOAuth","dataSource":"github-oauth"}}'
echo -e "${GREEN}  ✓ GitHub OAuth connector created${NC}"

# Get OAuth URL — fetch BEFORE ARM connector creation
TOKEN=$(get_agent_token)
GITHUB_CONFIG=$(curl -s "${AGENT_ENDPOINT}/api/v1/github/config" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null)
OAUTH_URL=$(echo "$GITHUB_CONFIG" | $PYTHON -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('oAuthUrl', '') or d.get('OAuthUrl', '') or '')
except: print('')
" 2>/dev/null)

# Create GitHub OAuth connector via ARM
az rest --method PUT \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
  --body '{"properties":{"dataConnectorType":"GitHubOAuth","dataSource":"github-oauth"}}' \
  --output none 2>/dev/null || true
echo -e "${GREEN}  ✓ GitHub OAuth connector (ARM)${NC}"

# Show OAuth URL — always show even if parsing failed
if [ -z "$OAUTH_URL" ]; then
  # Try extracting directly with grep
  OAUTH_URL=$(echo "$GITHUB_CONFIG" | grep -o 'https://github.com/login/oauth/authorize[^"]*' 2>/dev/null || echo "")
fi

if [ -n "$OAUTH_URL" ]; then
  echo ""
  echo -e "   ${YELLOW}┌──────────────────────────────────────────────────────────┐${NC}"
  echo -e "   ${YELLOW}│  Sign in to GitHub to authorize the SRE Agent:          │${NC}"
  echo -e "   ${YELLOW}│  ${OAUTH_URL}${NC}"
  echo -e "   ${YELLOW}│  Open this URL in your browser and click 'Authorize'    │${NC}"
  echo -e "   ${YELLOW}└──────────────────────────────────────────────────────────┘${NC}"
  echo ""
  read -p "   Press Enter after you have authorized in the browser..." _unused
else
  echo -e "${YELLOW}  ⚠️  Could not get OAuth URL. Sign in at: sre.azure.com → Connectors → github → Sign in${NC}"
  read -p "   Press Enter after you have signed in via the portal..." _unused
fi

# Add code repo after OAuth
TOKEN=$(get_agent_token)
REPO_NAME=$(echo "$GITHUB_REPO" | cut -d'/' -f2)
curl -s -o /dev/null -w "" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"type\":\"CodeRepo\",\"properties\":{\"url\":\"https://github.com/${GITHUB_REPO}\",\"authConnectorName\":\"github\"}}"
echo -e "${GREEN}  ✓ Code repo: ${GITHUB_REPO}${NC}"

# ---- Step 6: Create response plan ----
echo -e "\n${YELLOW}[6/7] Creating response plan...${NC}"
TOKEN=$(get_agent_token)

# Wait for Azure Monitor to be ready
echo "   Waiting for Azure Monitor to initialize..."
sleep 30

# Delete any existing filters
curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/vm-perf-alerts" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

# Create response plan
FILTER_CREATED=false
for attempt in 1 2 3 4 5; do
  TOKEN=$(get_agent_token)
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/vm-perf-alerts" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"id":"vm-perf-alerts","name":"VM Performance Alerts","priorities":["Sev0","Sev1","Sev2","Sev3","Sev4"],"titleContains":"","handlingAgent":"","agentMode":"autonomous","maxAttempts":3}')

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ] || [ "$HTTP_CODE" = "409" ]; then
    echo -e "${GREEN}  ✓ Response plan: vm-perf-alerts${NC}"
    FILTER_CREATED=true
    break
  else
    echo "   ⏳ Attempt $attempt/5: HTTP ${HTTP_CODE}, retrying in 15s..."
    sleep 15
  fi
done

if [ "$FILTER_CREATED" = "false" ]; then
  echo -e "${YELLOW}  Response plan failed after 5 attempts.${NC}"
fi

# Delete quickstart handler
TOKEN=$(get_agent_token)
curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_response_plan" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

# ---- Step 7: Verification ----
echo -e "\n${YELLOW}[7/7] Verifying setup...${NC}"
TOKEN=$(get_agent_token)

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

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Lab 1 setup complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Show VM IP
VM_IP=$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" --name "$VM_APP_NAME" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>/dev/null || echo "")
if [[ -n "$VM_IP" ]]; then
  echo -e "  🌐 App URL:        ${YELLOW}http://${VM_IP}${NC}"
fi
echo -e "  🤖 Agent Portal:   ${YELLOW}https://sre.azure.com${NC}"
echo ""
echo -e "  ${BLUE}Demo Scenarios:${NC}"
echo -e "  ┌─────────────────────────────────────────────────────────┐"
echo -e "  │  ${YELLOW}Scenario A: Database Break${NC}                             │"
echo -e "  │    bash scripts/break-db.sh stop                       │"
echo -e "  │    → App returns 500s, DB disconnected                 │"
echo -e "  │    → Ask: 'Why is the database disconnected?'          │"
echo -e "  │    bash scripts/break-db.sh restore                    │"
echo -e "  │                                                        │"
echo -e "  │  ${YELLOW}Scenario B: CPU Spike${NC}                                  │"
echo -e "  │    bash scripts/break-vm.sh cpu                        │"
echo -e "  │    → Wait 3-5 min for alert → agent investigates       │"
echo -e "  │    → Ask: 'Check CPU on vm-sap-app-01'                │"
echo -e "  │                                                        │"
echo -e "  │  ${YELLOW}Scenario C: Compliance Drift${NC}                           │"
echo -e "  │    bash scripts/break-vm.sh drift                      │"
echo -e "  │    → NSG rules changed, tags removed                   │"
echo -e "  │    → Ask: 'Run a compliance scan'                      │"
echo -e "  └─────────────────────────────────────────────────────────┘"
echo ""
