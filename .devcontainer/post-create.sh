#!/bin/bash
# =============================================================================
# Post-Create Script for Azure SRE Agent Lab Dev Container
# Runs once when the container is first created.
# =============================================================================
set -e

echo "Setting up Azure SRE Agent Lab environment..."

# Install system packages (python3-yaml is pre-compiled, much faster than pip)
sudo apt-get update && sudo apt-get install -y --no-install-recommends python3-yaml jq

echo "Setup complete."
