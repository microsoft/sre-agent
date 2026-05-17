#!/bin/bash
# ============================================================
# Break Database — Break/restore private endpoint DNS config
#
# Usage:
#   bash scripts/break-db.sh break    # Delete DNS link → app loses DB
#   bash scripts/break-db.sh restore  # Recreate DNS link → app reconnects
# ============================================================
set -e

ACTION="${1:-break}"

RESOURCE_GROUP=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "")
if [ -z "$RESOURCE_GROUP" ]; then
  ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "ebc-demo3")
  RESOURCE_GROUP="rg-${ENV_NAME}"
fi

VNET_NAME=$(az network vnet list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
DNS_ZONE="privatelink.documents.azure.com"
DNS_LINK="dnslink-${VNET_NAME}"

echo ""
echo "============================================="
echo "  Private Endpoint DNS Break"
echo "============================================="
echo "  RG:       $RESOURCE_GROUP"
echo "  VNet:     $VNET_NAME"
echo "  DNS Link: $DNS_LINK"
echo ""

case "$ACTION" in
  break)
    echo "Deleting DNS zone VNet link..."
    echo "This breaks private DNS resolution → app can't find Cosmos DB"
    echo ""
    az network private-dns link vnet delete \
      --resource-group "$RESOURCE_GROUP" \
      --zone-name "$DNS_ZONE" \
      --name "$DNS_LINK" \
      --yes \
      --output none 2>/dev/null

    echo "  ✅ DNS link deleted"
    echo ""
    echo "  The VM can no longer resolve cosmos-*.documents.azure.com"
    echo "  to the private IP. Public access is also disabled."
    echo "  → App health check will show 'database: disconnected'"
    echo ""
    echo "  Wait ~30 seconds for DNS cache to expire, then refresh the app."
    echo ""
    echo "  Ask the agent:"
    echo "    'Our ecommerce app seems to be down. What's going on?'"
    ;;

  restore)
    echo "Recreating DNS zone VNet link..."
    az network private-dns link vnet create \
      --resource-group "$RESOURCE_GROUP" \
      --zone-name "$DNS_ZONE" \
      --name "$DNS_LINK" \
      --virtual-network "$VNET_NAME" \
      --registration-enabled false \
      --output none 2>/dev/null

    echo "  ✅ DNS link restored"
    echo ""
    echo "  The VM can now resolve to the private IP again."
    echo "  App should reconnect within ~30 seconds."
    ;;

  *)
    echo "Usage: bash scripts/break-db.sh [break|restore]"
    exit 1
    ;;
esac
echo "============================================="
