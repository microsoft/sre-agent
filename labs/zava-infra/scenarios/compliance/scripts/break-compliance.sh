#!/bin/bash
# ============================================================
# break-compliance.sh — Trigger a non-compliant deployment
#
# Builds a dummy image locally, pushes to ACR, and deploys
# to the Container App — all via Azure CLI (your user identity).
#
# The SRE Agent will detect this as NON-COMPLIANT because:
#   1. claims.appid = Azure CLI (04b07795-8ddb-461a-bbee-02f9e1bf7b46)
#   2. No pipeline resource tags (deployed-by, commit-sha, etc.)
#
# Usage:
#   bash scripts/break-compliance.sh
# ============================================================
set -euo pipefail

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---- Resolve from azd env or defaults ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$DEMO_DIR"

RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "rg-compliancedemo")
ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
CONTAINER_APP=$(azd env get-value CONTAINER_APP_NAME 2>/dev/null || echo "")

if [ -z "$ACR_NAME" ] || [ -z "$CONTAINER_APP" ]; then
  echo -e "${RED}❌ Could not resolve ACR or Container App name from azd env.${NC}"
  echo "   Run 'azd provision' first, or set AZURE_CONTAINER_REGISTRY_NAME and CONTAINER_APP_NAME."
  exit 1
fi

ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
IMAGE_NAME="compliance-demo-api"
TAG="rogue-$(date +%s)"
FULL_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${TAG}"

echo -e "${YELLOW}=============================================${NC}"
echo -e "${YELLOW}  Triggering NON-COMPLIANT deployment${NC}"
echo -e "${YELLOW}=============================================${NC}"
echo ""
echo -e "  ACR:    ${ACR_NAME}"
echo -e "  App:    ${CONTAINER_APP}"
echo -e "  Image:  ${FULL_IMAGE}"
echo -e "  Caller: ${RED}Azure CLI (your user identity)${NC}"
echo -e "  Tags:   ${RED}None (no pipeline tags)${NC}"
echo ""

# ---- Build a dummy image directly in ACR (no local Docker needed) ----
echo -e "${YELLOW}[1/3] Building rogue image in ACR...${NC}"

az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE_NAME}:${TAG}" \
  --file "src/api/Dockerfile" \
  "src/api/" \
  --no-logs --output none

echo -e "${GREEN}  ✅ Image built: ${FULL_IMAGE}${NC}"

# ---- Deploy WITHOUT pipeline tags (non-compliant) ----
echo -e "${YELLOW}[2/3] Deploying via Azure CLI (non-compliant)...${NC}"

az containerapp update \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --image "$FULL_IMAGE" \
  --output none

echo -e "${GREEN}  ✅ Deployed (no pipeline tags)${NC}"

# ---- Verify ----
echo -e "${YELLOW}[3/3] Verifying deployment...${NC}"

FQDN=$(az containerapp show \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null)

if [ -n "$FQDN" ]; then
  echo -e "${GREEN}  ✅ App URL: https://${FQDN}${NC}"
else
  echo -e "${YELLOW}  ⚠️  Could not get FQDN${NC}"
fi

echo ""
echo -e "${RED}=============================================${NC}"
echo -e "${RED}  ⚠️  NON-COMPLIANT deployment triggered!${NC}"
echo -e "${RED}=============================================${NC}"
echo ""
echo "  The Activity Log now records this deployment with:"
echo "    • Caller: your user identity (not a service principal)"
echo "    • claims.appid: Azure CLI"
echo "    • No resource tags (deployed-by, commit-sha, etc.)"
echo ""
echo "  Wait 5-15 minutes for the Activity Log to reach LAW,"
echo "  then ask the agent:"
echo ""
echo "    \"Check deployment compliance for the last 30 minutes\""
echo ""
echo "  Or wait for the alert to fire and the response plan to"
echo "  trigger the compliance check automatically."
echo ""
