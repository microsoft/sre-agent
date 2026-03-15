#!/bin/bash
# ============================================================
# Deploy the latest image from ACR to the Container App
# Run after GitHub Actions pushes a new image to ACR.
#
# Usage:
#   bash scripts/deploy.sh                    # deploy :latest
#   bash scripts/deploy.sh <commit-sha>       # deploy specific version
# ============================================================
set -euo pipefail

RESOURCE_GROUP="rg-compliancedemo"
CONTAINER_APP="ca-api-compliancedemo"
ACR_NAME="acrcompliancedemoenqgb2"
IMAGE="compliance-demo-api"

TAG="${1:-latest}"
FULL_IMAGE="${ACR_NAME}.azurecr.io/${IMAGE}:${TAG}"

echo "Deploying: $FULL_IMAGE"
az containerapp update \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --image "$FULL_IMAGE" \
  --output none

FQDN=$(az containerapp show \
  --name "$CONTAINER_APP" \
  --resource-group "$RESOURCE_GROUP" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "✅ Deployed! App: https://$FQDN"
sleep 10
echo "Health check:"
curl -s "https://$FQDN/health" | python3 -m json.tool
