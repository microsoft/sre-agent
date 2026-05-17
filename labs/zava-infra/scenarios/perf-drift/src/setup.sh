#!/bin/bash
# Setup script for E-Commerce app on VM
# Installs Node.js and the web app — connects to Azure SQL

set -e

DB_HOST="${1}"
DB_PASSWORD="${2}"
DB_USER="${3:-sqladmin}"
DB_NAME="${4:-ecommerce}"

echo "=== Installing Node.js 20 ==="
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

echo "=== Setting up app directory ==="
mkdir -p /opt/ecommerce
cd /opt/ecommerce

echo "=== Installing dependencies ==="
cat > package.json << 'PKGEOF'
{"name":"ecommerce-api","version":"1.0.0","dependencies":{"express":"^4.18.2","mssql":"^10.0.2"}}
PKGEOF
npm install --production 2>/dev/null

echo "=== Creating systemd service ==="
cat > /etc/systemd/system/ecommerce.service << EOF
[Unit]
Description=E-Commerce API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ecommerce
Environment=PORT=80
Environment=DB_HOST=${DB_HOST}
Environment=DB_NAME=${DB_NAME}
Environment=DB_USER=${DB_USER}
Environment=DB_PASSWORD=${DB_PASSWORD}
ExecStart=/usr/bin/node app.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ecommerce
systemctl restart ecommerce

echo "=== E-Commerce API started ==="
echo "DB_HOST: ${DB_HOST}"
echo "Listening on port 80"
