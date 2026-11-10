#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
sudo mkdir -p /var/log/sre-lab
sudo chmod 0755 /var/log/sre-lab
docker compose up -d --build
docker compose ps
echo "Watch traffic with: docker compose logs -f loadgen"
