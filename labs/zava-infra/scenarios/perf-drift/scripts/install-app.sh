#!/bin/bash
# Quick install script — run from lab directory
set -e

cd "$(dirname "$0")/.."
COSMOS_ENDPOINT=$(azd env get-value COSMOS_ENDPOINT)
COSMOS_DB_NAME=$(azd env get-value COSMOS_DB_NAME)
RG=$(azd env get-value RESOURCE_GROUP_NAME 2>/dev/null || echo "rg-$(azd env get-value AZURE_ENV_NAME)")
VM_NAME="vm-sap-app-01"
APP_B64=$(base64 < src/app.js)

echo "Installing app on $VM_NAME..."
echo "Cosmos: $COSMOS_ENDPOINT"

az vm run-command invoke -g "$RG" -n "$VM_NAME" --command-id RunShellScript \
  --scripts "
set -e
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
mkdir -p /opt/ecommerce && cd /opt/ecommerce
echo '{\"name\":\"ecommerce\",\"dependencies\":{\"express\":\"^4.18.2\",\"@azure/cosmos\":\"^4.0.0\",\"@azure/identity\":\"^4.0.0\"}}' > package.json
npm install --production 2>/dev/null
echo '$APP_B64' | base64 -d > app.js
cat > /etc/systemd/system/ecommerce.service <<SVCEOF
[Unit]
Description=E-Commerce API
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/ecommerce
Environment=PORT=80
Environment=COSMOS_ENDPOINT=$COSMOS_ENDPOINT
Environment=COSMOS_DB_NAME=$COSMOS_DB_NAME
ExecStart=/usr/bin/node app.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable ecommerce
systemctl restart ecommerce
sleep 3
curl -s http://localhost/api/health || echo starting
" --query "value[0].message" -o tsv

echo ""
VM_IP=$(az vm list-ip-addresses -g "$RG" -n "$VM_NAME" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
echo "App URL: http://$VM_IP"
