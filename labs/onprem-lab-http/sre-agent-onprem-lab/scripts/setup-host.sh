#!/usr/bin/env bash
set -euo pipefail
if [[ $EUID -eq 0 ]]; then echo "Run as your normal sudo-enabled user, not root." >&2; exit 1; fi
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
REPO
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
sudo mkdir -p /var/log/sre-lab
sudo chmod 0755 /var/log/sre-lab
cat <<MSG
Docker is installed. Sign out and back in (or run 'newgrp docker'), then run:
  ./scripts/start-lab.sh
MSG
