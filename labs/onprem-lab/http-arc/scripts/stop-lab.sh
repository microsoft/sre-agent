#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/fault.sh reset 2>/dev/null || true
docker compose down
