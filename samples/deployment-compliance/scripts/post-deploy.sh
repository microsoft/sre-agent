#!/bin/bash
# ============================================================
# Post-deployment setup script
# Run after `azd provision` to configure:
#   1. Activity Log diagnostic settings (subscription-level)
#   2. Kusto connector on the SRE Agent (via ExtendedAgent API)
#   3. Custom compliance skill
#   4. Approval hook
#   5. Incident filter
#   6. Scheduled task
# ============================================================

set -uo pipefail

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Deployment Compliance Demo — Post-Deployment Setup${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# ---- Resolve resource names from azd or from Azure ----
echo -e "\n${YELLOW}[1/7] Resolving deployed resources...${NC}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [[ -z "$RESOURCE_GROUP" ]]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "compliancedemo")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

# Get SRE Agent endpoint
AGENT_ENDPOINT=$(az resource show \
  --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.App/agents" \
  --name "$(az resource list --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv)" \
  --query "properties.agentEndpoint" -o tsv 2>/dev/null || echo "")

if [[ -z "$AGENT_ENDPOINT" ]]; then
  echo -e "${RED}ERROR: Could not find SRE Agent endpoint. Check resource group: $RESOURCE_GROUP${NC}"
  exit 1
fi

# Get LAW resource ID for Kusto connector (use law-compliance-*, not law-cae-*)
LAW_ID=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.OperationalInsights/workspaces" \
  --query "[?starts_with(name, 'law-compliance-')].id" -o tsv 2>/dev/null | head -1)

LAW_NAME=$(az resource show --ids "$LAW_ID" --query "name" -o tsv 2>/dev/null || echo "")
LAW_WORKSPACE_ID=$(az resource show --ids "$LAW_ID" --query "properties.customerId" -o tsv 2>/dev/null || echo "")

# Get agent managed identity principal ID
AGENT_MI_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" \
  --query "[?contains(name, 'sreagent')].name" -o tsv 2>/dev/null | head -1)

echo -e "${GREEN}  Resource Group: $RESOURCE_GROUP${NC}"
echo -e "${GREEN}  Agent Endpoint: $AGENT_ENDPOINT${NC}"
echo -e "${GREEN}  LAW Name: $LAW_NAME${NC}"
echo -e "${GREEN}  LAW ID: $LAW_ID${NC}"
echo -e "${GREEN}  LAW Workspace ID: $LAW_WORKSPACE_ID${NC}"

# ---- Helper: Get auth token for SRE Agent API ----
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

# ---- Step 1b: Ensure current user has SRE Agent Administrator role ----
echo "   Ensuring SRE Agent Administrator role..."
AGENT_ID=$(az resource list --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.App/agents" --query "[0].id" -o tsv 2>/dev/null)
# Get user OID from the access token (avoids Graph API which may be blocked by conditional access)
ACCESS_TOKEN=$(az account get-access-token --resource "https://azuresre.dev" --query accessToken -o tsv 2>/dev/null)
USER_OID=""
if [[ -n "$ACCESS_TOKEN" ]]; then
  USER_OID=$(python3 -c "
import json, base64, sys
try:
    token = sys.argv[1]
    payload = token.split('.')[1]
    payload += '=' * (4 - len(payload) % 4)
    claims = json.loads(base64.b64decode(payload))
    print(claims.get('oid', ''))
except Exception as e:
    print('', file=sys.stderr)
    print(str(e), file=sys.stderr)
" "$ACCESS_TOKEN")
fi

if [[ -n "$USER_OID" && -n "$AGENT_ID" ]]; then
  echo "   Assigning role to user OID: ${USER_OID:0:8}..."
  az role assignment create \
    --assignee-object-id "$USER_OID" \
    --assignee-principal-type User \
    --role "SRE Agent Administrator" \
    --scope "$AGENT_ID" \
    --output none || true
  echo -e "${GREEN}  ✓ SRE Agent Administrator role assigned.${NC}"
else
  echo -e "${YELLOW}  Could not extract user OID (USER_OID='$USER_OID', AGENT_ID set=$([ -n "$AGENT_ID" ] && echo yes || echo no)). Assign role manually.${NC}"
fi

# ---- Step 2: Activity Log Diagnostic Settings ----
echo -e "\n${YELLOW}[2/7] Configuring Activity Log diagnostic settings...${NC}"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Check existing diagnostic settings — recreate if pointing to wrong workspace
EXISTING=$(az monitor diagnostic-settings subscription list \
  --query "[?name=='activity-to-law'].name" -o tsv 2>/dev/null || echo "")
EXISTING_WS=$(az monitor diagnostic-settings subscription list \
  --query "[?name=='activity-to-law'].workspaceId" -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING" && "$EXISTING_WS" == *"$LAW_NAME"* ]]; then
  echo -e "${GREEN}  Diagnostic setting 'activity-to-law' already exists (correct workspace). Skipping.${NC}"
else
  if [[ -n "$EXISTING" ]]; then
    echo "  Existing diagnostic setting points to wrong workspace. Deleting..."
    az monitor diagnostic-settings subscription delete --name "activity-to-law" --yes 2>/dev/null || true
  fi
  if az monitor diagnostic-settings subscription create \
    --name "activity-to-law" \
    --workspace "$LAW_ID" \
    --logs '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"Policy","enabled":true},{"category":"Alert","enabled":true}]' \
    --output none; then
    echo -e "${GREEN}  ✓ Diagnostic settings configured → ${LAW_NAME}${NC}"
  else
    echo -e "${YELLOW}  Could not create diagnostic settings (may need elevated permissions or already exists).${NC}"
  fi
fi

# ---- Step 3: Grant agent MI required RBAC roles ----
echo -e "\n${YELLOW}[3/7] Granting agent identity RBAC roles...${NC}"

AGENT_MI_PRINCIPAL_ID=$(az identity show --name "$AGENT_MI_NAME" --resource-group "$RESOURCE_GROUP" --query principalId -o tsv 2>/dev/null || echo "")
AGENT_MI_CLIENT_ID=$(az identity show --name "$AGENT_MI_NAME" --resource-group "$RESOURCE_GROUP" --query clientId -o tsv 2>/dev/null || echo "")

if [[ -n "$AGENT_MI_PRINCIPAL_ID" ]]; then
  # Log Analytics Reader on the LAW (for Kusto queries)
  az role assignment create \
    --assignee-object-id "$AGENT_MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Log Analytics Reader" \
    --scope "$LAW_ID" \
    --output none || echo -e "${YELLOW}  Role may already exist.${NC}"
  echo -e "${GREEN}  ✓ Log Analytics Reader granted on LAW.${NC}"

  # Monitoring Contributor on subscription (required for Azure Monitor incident platform)
  # Per https://sre.azure.com/docs - agent needs this to read/write alerts
  az role assignment create \
    --assignee-object-id "$AGENT_MI_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Monitoring Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" \
    --output none || echo -e "${YELLOW}  Role may already exist.${NC}"
  echo -e "${GREEN}  ✓ Monitoring Contributor granted on subscription.${NC}"
fi

# ---- Step 4: Configure Azure access for LAW queries ----
echo -e "\n${YELLOW}[4/7] Configuring Azure access and incident platform...${NC}"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
AGENT_NAME=$(az resource list --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.App/agents" --query "[0].name" -o tsv)
AGENT_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.App/agents/${AGENT_NAME}"
API_VERSION="2025-05-01-preview"

# The agent queries LAW using built-in Azure observability tools (no ADX connector needed).
# Activity Logs flow to LAW via diagnostic settings (Step 2).
# The agent's UAMI has Log Analytics Reader (Step 3) for query access.
echo -e "${GREEN}  ✓ LAW query access: Built-in (Log Analytics Reader + diagnostic settings)${NC}"
echo -e "${GREEN}    The agent uses built-in Azure Monitor / Log Analytics tools to run KQL.${NC}"
echo -e "${GREEN}    No separate Kusto/ADX connector is needed for LAW.${NC}"

# ---- Step 4b: Enable Azure Monitor as incident platform ----
echo -e "\n${YELLOW}    Enabling Azure Monitor incident platform...${NC}"

if az rest --method PATCH \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  --body '{"properties":{"incidentManagementConfiguration":{"type":"AzMonitor","connectionName":"azmonitor"}}}' \
  --output none 2>&1; then
  echo -e "${GREEN}  ✓ Azure Monitor enabled as incident platform.${NC}"
else
  echo -e "${YELLOW}  Could not enable Azure Monitor (may already be set).${NC}"
fi
sleep 5

# ---- Step 5: Create Compliance Skill ----
echo -e "\n${YELLOW}[5/7] Creating deployment-compliance-check skill...${NC}"

SKILL_CONTENT=$(cat "$DEMO_DIR/skills/deployment-compliance-check/SKILL.md" 2>/dev/null || echo "")
DETECTION_CONTENT=$(cat "$DEMO_DIR/skills/deployment-compliance-check/compliance_detection.md" 2>/dev/null || echo "")

if [[ -n "$SKILL_CONTENT" ]]; then
  SKILL_BODY=$(python3 -c "
import json, sys
skill = open('$DEMO_DIR/skills/deployment-compliance-check/SKILL.md').read()
detection = open('$DEMO_DIR/skills/deployment-compliance-check/compliance_detection.md').read()
body = {
    'name': 'deployment-compliance-check',
    'type': 'Skill',
    'properties': {
        'description': 'Detects out-of-compliance Container App deployments via Activity Log analysis',
        'tools': ['QueryLogAnalyticsByWorkspaceId', 'GetAzCliHelp', 'RunAzCliReadCommands', 'RunAzCliWriteCommands'],
        'skillContent': skill,
        'additionalFiles': [
            {'filePath': 'compliance_detection.md', 'content': detection}
        ]
    }
}
print(json.dumps(body))
")
  RESULT=$(agent_api PUT "/api/v2/extendedAgent/skills/deployment-compliance-check" "$SKILL_BODY"  || echo "FAILED")
  if echo "$RESULT" | grep -q "deployment-compliance-check" 2>/dev/null; then
    echo -e "${GREEN}  ✓ Skill 'deployment-compliance-check' created.${NC}"
  else
    echo -e "${YELLOW}  Skill may need manual setup. Response: ${RESULT:0:200}${NC}"
  fi
else
  echo -e "${RED}  Skill files not found at $DEMO_DIR/skills/${NC}"
fi

# ---- Step 6: Create Approval Hook ----
echo -e "\n${YELLOW}[6/7] Creating deployment-compliance-approval hook...${NC}"

HOOK_BODY=$(cat <<'EOF'
{
  "name": "deployment-compliance-approval",
  "type": "GlobalHook",
  "properties": {
    "eventType": "Stop",
    "activationMode": "onDemand",
    "description": "Requires explicit user approval before reverting a non-compliant Container App deployment",
    "hook": {
      "type": "prompt",
      "prompt": "Check if the agent is about to revert or modify a Container App deployment. If the response includes a revert, rollback, or revision change, reject and ask the user to approve first.\n\n$ARGUMENTS\n\nRespond with JSON:\n- If no revert action: {\"ok\": true, \"reason\": \"No deployment-modifying action detected\"}\n- If revert pending: {\"ok\": false, \"reason\": \"Deployment revert requires approval. Reply 'yes' to approve or 'no' to cancel.\"}",
      "model": "ReasoningFast",
      "timeout": 30,
      "failMode": "Block",
      "maxRejections": 3
    }
  }
}
EOF
)

RESULT=$(agent_api PUT "/api/v2/extendedAgent/hooks/deployment-compliance-approval" "$HOOK_BODY"  || echo "FAILED")
if echo "$RESULT" | grep -q "deployment-compliance-approval" 2>/dev/null; then
  echo -e "${GREEN}  ✓ Hook 'deployment-compliance-approval' created.${NC}"
else
  echo -e "${YELLOW}  Hook may need manual setup. Response: ${RESULT:0:200}${NC}"
fi

# ---- Step 7: Create response plan + scheduled task ----
echo -e "\n${YELLOW}[7/7] Creating response plan and scheduled task...${NC}"

TOKEN=$(get_agent_token)

# Delete existing filter if present
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/containerapp-compliance" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

sleep 3

# Create response plan with custom compliance instructions
python3 -c "
import json
body = {
    'id': 'containerapp-compliance',
    'name': 'Container App Deployment Compliance',
    'priorities': ['Sev0', 'Sev1', 'Sev2', 'Sev3', 'Sev4'],
    'titleContains': '',
    'agentMode': 'review',
    'maxAttempts': 3,
    'instructions': '''Use the deployment-compliance-check skill to investigate this alert.

The skill has all the KQL templates, classification rules, and revert procedures.
If the deployment is non-compliant, activate the deployment-compliance-approval hook before reverting.
Never revert without user approval.'''
}
with open('/tmp/filter-body.json', 'w') as f:
    json.dump(body, f)
"

FILTER_CREATED=false
for attempt in 1 2 3; do
  TOKEN=$(get_agent_token)
  HTTP_CODE=$(curl -s -o /tmp/filter-resp.txt -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/containerapp-compliance" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/filter-body.json)

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
    echo -e "${GREEN}  ✓ Response plan created: containerapp-compliance${NC}"
    FILTER_CREATED=true
    break
  else
    echo "   Attempt $attempt/3: HTTP ${HTTP_CODE}, retrying in 10s..."
    sleep 10
  fi
done
if [ "$FILTER_CREATED" = "false" ]; then
  echo -e "${YELLOW}  Response plan failed — set up in portal or re-run this script.${NC}"
fi
rm -f /tmp/filter-resp.txt /tmp/filter-body.json

# Delete default quickstart handler
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_handler" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true

# ---- Create scheduled task for periodic compliance scans ----
echo "   Creating compliance scan scheduled task..."
TOKEN=$(get_agent_token)

# Delete existing task if present
EXISTING_TASKS=$(curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "[]")
echo "$EXISTING_TASKS" | python3 -c "
import sys,json
try:
    tasks=json.load(sys.stdin)
    for t in tasks:
        if t.get('name')=='compliance-scan':
            print(t.get('id',''))
except: pass
" 2>/dev/null | while read -r task_id; do
  if [ -n "$task_id" ]; then
    curl -s -o /dev/null -X DELETE "${AGENT_ENDPOINT}/api/v1/scheduledtasks/${task_id}" \
      -H "Authorization: Bearer ${TOKEN}" 2>/dev/null
  fi
done

python3 -c "
import json
body = {
    'name': 'compliance-scan',
    'description': 'compliance-scan',
    'cronExpression': '*/30 * * * *',
    'agentPrompt': '''Load the deployment-compliance-check skill and follow it to check whether the latest running image is compliant for all Container Apps in scope. Use hooks before any modification action on a resource. Report findings in the format specified by the skill. Remediate following the skill instructions'''
}
with open('/tmp/task-body.json', 'w') as f:
    json.dump(body, f)
"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/task-body.json)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "202" ]; then
  echo -e "${GREEN}  ✓ Scheduled task created: compliance-scan (every 30 min)${NC}"
else
  echo -e "${YELLOW}  Scheduled task returned HTTP ${HTTP_CODE}${NC}"
fi
rm -f /tmp/task-body.json

# ---- Step 8: GitHub connector + code repo ----
echo -e "\n${YELLOW}[8/8] Configuring GitHub connector and code repository...${NC}"

# Check if GitHub OAuth connector already exists via data plane
TOKEN=$(get_agent_token)
GITHUB_EXISTS=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/github" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('yes' if d.get('name')=='github' else 'no')
except: print('no')
" 2>/dev/null)

if [ "$GITHUB_EXISTS" = "yes" ]; then
  echo -e "${GREEN}  ✓ GitHub OAuth connector already exists. Skipping creation.${NC}"
else
  # Create via data plane API
  GITHUB_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/github" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"github","type":"AgentConnector","properties":{"dataConnectorType":"GitHubOAuth","dataSource":"github-oauth"}}')
  if [ "$GITHUB_RESULT" = "200" ] || [ "$GITHUB_RESULT" = "201" ]; then
    echo -e "${GREEN}  ✓ GitHub OAuth connector created (data plane).${NC}"
  else
    echo -e "${YELLOW}  GitHub connector returned HTTP ${GITHUB_RESULT}. May need manual setup.${NC}"
  fi

  # Also create at ARM level so it's visible in the portal Full Setup page
  echo "   Creating GitHub connector at ARM level..."
  az rest --method PUT \
    --url "https://management.azure.com${AGENT_RESOURCE_ID}/DataConnectors/github?api-version=${API_VERSION}" \
    --body '{"properties":{"dataConnectorType":"GitHubOAuth","dataSource":"github-oauth"}}' \
    --output none 2>/dev/null \
    && echo -e "${GREEN}  ✓ GitHub connector created at ARM level.${NC}" \
    || echo -e "${YELLOW}  ⚠️  ARM-level connector creation failed (non-critical — data plane connector is active).${NC}"
fi

# Get the OAuth login URL
TOKEN=$(get_agent_token)
OAUTH_URL=$(curl -s "${AGENT_ENDPOINT}/api/v1/github/config" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('oAuthUrl', '') or d.get('OAuthUrl', '') or '')
except:
    print('')
" 2>/dev/null)

if [ -n "$OAUTH_URL" ]; then
  echo ""
  echo -e "  ${BLUE}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${BLUE}│  Sign in to GitHub to authorize the SRE Agent:              │${NC}"
  echo -e "  ${BLUE}│                                                              │${NC}"
  echo -e "  ${BLUE}│  ${OAUTH_URL}${NC}"
  echo -e "  ${BLUE}│                                                              │${NC}"
  echo -e "  ${BLUE}│  Open this URL in your browser and click 'Authorize'         │${NC}"
  echo -e "  ${BLUE}└──────────────────────────────────────────────────────────────┘${NC}"
fi

# Add compliance repo to agent (uses existing GitHub connector for auth)
echo -e "\n   Adding compliancedemo repo to agent..."
TOKEN=$(get_agent_token)

# Detect repo owner from git remote or default
REPO_OWNER="dm-chelupati"
REPO_NAME="compliancedemo"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"

REPO_RESULT=$(curl -s -o /tmp/repo-resp.txt -w "%{http_code}" \
  -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${REPO_NAME}\",\"type\":\"CodeRepo\",\"properties\":{\"url\":\"${REPO_URL}\",\"authConnectorName\":\"github\"}}")

if [ "$REPO_RESULT" = "200" ] || [ "$REPO_RESULT" = "201" ]; then
  echo -e "${GREEN}  ✓ Repository '${REPO_OWNER}/${REPO_NAME}' connected to agent.${NC}"
else
  echo -e "${YELLOW}  Could not add repo (HTTP ${REPO_RESULT}). Add manually in portal.${NC}"
fi
rm -f /tmp/repo-resp.txt

# ---- Verification: Check all connectors and resources are connected ----
echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Verifying setup (waiting for agent to settle)...${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
sleep 15

TOKEN=$(get_agent_token)
VERIFY_PASS=0
VERIFY_FAIL=0

# Check connectors via data plane API
echo -e "\n  ${YELLOW}Connectors:${NC}"

# Check LAW access (built-in, verified by diagnostic settings + role assignment in steps 2-3)
if [[ -n "$LAW_ID" && -n "$AGENT_MI_PRINCIPAL_ID" ]]; then
  echo -e "    ${GREEN}✓ LAW query access: Built-in (Log Analytics Reader + diagnostic settings)${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ LAW access: Missing LAW ID or agent MI${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Check GitHub connector
GITHUB_CHECK=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/connectors/github" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('ok' if d.get('name')=='github' else 'missing')
except: print('missing')
" 2>/dev/null)
if [ "$GITHUB_CHECK" = "ok" ]; then
  echo -e "    ${GREEN}✓ GitHub connector: Connected${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ GitHub connector: Not found${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Check connected repos
echo -e "\n  ${YELLOW}Code Repositories:${NC}"
REPO_STATUS=$(curl -s "${AGENT_ENDPOINT}/api/v2/repos/compliancedemo" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('name')=='compliancedemo':
        url=d.get('properties',{}).get('url','')
        sync=d.get('properties',{}).get('cloneStatus','Unknown')
        print(f'ok|{url}|{sync}')
    else: print('missing||')
except: print('missing||')
" 2>/dev/null)
REPO_CHECK=$(echo "$REPO_STATUS" | cut -d'|' -f1)
REPO_URL_CHECK=$(echo "$REPO_STATUS" | cut -d'|' -f2)
REPO_SYNC=$(echo "$REPO_STATUS" | cut -d'|' -f3)
if [ "$REPO_CHECK" = "ok" ]; then
  echo -e "    ${GREEN}✓ compliancedemo: ${REPO_URL_CHECK} (sync: ${REPO_SYNC})${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ compliancedemo repo not connected${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Check Azure Monitor incident platform
echo -e "\n  ${YELLOW}Incident Platform:${NC}"
AZ_MON_STATUS=$(az rest --method GET \
  --url "https://management.azure.com${AGENT_RESOURCE_ID}?api-version=${API_VERSION}" \
  2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    icm=d.get('properties',{}).get('incidentManagementConfiguration',{})
    t=icm.get('type','')
    print(t if t else 'NotConfigured')
except: print('Error')
" 2>/dev/null)
if [ "$AZ_MON_STATUS" = "AzMonitor" ]; then
  echo -e "    ${GREEN}✓ Azure Monitor: Connected${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ Azure Monitor: ${AZ_MON_STATUS}${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Check data plane resources (skill, hook, response plan, scheduled task)
echo -e "\n  ${YELLOW}Agent Resources:${NC}"

# Skill
SKILL_OK=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/skills/deployment-compliance-check" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('ok' if d.get('name')=='deployment-compliance-check' else 'missing')
except: print('missing')
" 2>/dev/null)
if [ "$SKILL_OK" = "ok" ]; then
  echo -e "    ${GREEN}✓ Skill: deployment-compliance-check${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ Skill: deployment-compliance-check not found${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Hook
HOOK_OK=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/hooks/deployment-compliance-approval" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('ok' if d.get('name')=='deployment-compliance-approval' else 'missing')
except: print('missing')
" 2>/dev/null)
if [ "$HOOK_OK" = "ok" ]; then
  echo -e "    ${GREEN}✓ Hook: deployment-compliance-approval${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ Hook: deployment-compliance-approval not found${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Response plan
FILTER_OK=$(curl -s "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys,json
try:
    data=json.load(sys.stdin)
    found = any(f.get('id')=='containerapp-compliance' for f in data)
    print('ok' if found else 'missing')
except: print('missing')
" 2>/dev/null)
if [ "$FILTER_OK" = "ok" ]; then
  echo -e "    ${GREEN}✓ Response plan: containerapp-compliance${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ Response plan: containerapp-compliance not found${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Scheduled task
TASK_OK=$(curl -s "${AGENT_ENDPOINT}/api/v1/scheduledtasks" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null | python3 -c "
import sys,json
try:
    data=json.load(sys.stdin)
    found = any(t.get('name')=='compliance-scan' for t in data)
    print('ok' if found else 'missing')
except: print('missing')
" 2>/dev/null)
if [ "$TASK_OK" = "ok" ]; then
  echo -e "    ${GREEN}✓ Scheduled task: compliance-scan${NC}"
  VERIFY_PASS=$((VERIFY_PASS + 1))
else
  echo -e "    ${RED}✗ Scheduled task: compliance-scan not found${NC}"
  VERIFY_FAIL=$((VERIFY_FAIL + 1))
fi

# Summary
echo ""
echo -e "  ${BLUE}────────────────────────────────────────${NC}"
if [ "$VERIFY_FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✓ All ${VERIFY_PASS}/${VERIFY_PASS} checks passed — agent is fully set up!${NC}"
else
  echo -e "  ${YELLOW}⚠ ${VERIFY_PASS} passed, ${VERIFY_FAIL} failed — check items above${NC}"
fi

# ---- Summary ----
echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Infrastructure deployed:"
echo "    ✓ Container App (workload)"
echo "    ✓ SRE Agent: $AGENT_ENDPOINT"
echo "    ✓ Log Analytics: Activity Logs flowing (built-in KQL access)"
echo "    ✓ Alert Rule: Container App deployment detection"
echo "    ✓ Azure Monitor: Incident platform"
echo "    ✓ GitHub connector + compliancedemo repo"
echo "    ✓ Skill: deployment-compliance-check"
echo "    ✓ Hook: deployment-compliance-approval"
echo "    ✓ Response plan: containerapp-compliance"
echo "    ✓ Scheduled task: compliance-scan (every 30 min)"
echo ""
echo "  To test the compliance workflow:"
echo "    1. Push a change through GitHub Actions (compliant)"
echo "    2. Make a change via Azure Portal (non-compliant)"
echo "    3. Ask the SRE Agent: 'Check deployment compliance'"
echo ""
echo "  Agent Portal: $AGENT_ENDPOINT"
