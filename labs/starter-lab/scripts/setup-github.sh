#!/bin/bash
# setup-github.sh — Add GitHub OAuth and the Grubify repository to an existing starter-lab agent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

GITHUB_USER="${1:-$(azd env get-value GITHUB_USER 2>/dev/null || true)}"
if echo "$GITHUB_USER" | grep -q "ERROR\|not found"; then
  GITHUB_USER=""
fi

if [ -z "$GITHUB_USER" ]; then
  echo "Usage: bash scripts/setup-github.sh <github-username>"
  echo "Fork https://github.com/dm-chelupati/grubify before running this command."
  exit 1
fi

if [ "$GITHUB_USER" = "dm-chelupati" ]; then
  echo "Use your own GitHub username and Grubify fork."
  exit 1
fi

azd env set GITHUB_USER "$GITHUB_USER"
bash "$SCRIPT_DIR/post-provision.sh" --retry
