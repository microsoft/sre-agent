#!/usr/bin/env bash
set -euo pipefail
URL="${LAB_URL:-http://localhost:8080}/lab/fault"
case "${1:-status}" in
  http500) mode=http500 ;;
  reset|normal) mode=normal ;;
  status) curl -fsS "$URL"; echo; exit 0 ;;
  *) echo "Usage: $0 [http500|reset|status]" >&2; exit 1 ;;
esac
curl -fsS -X POST "$URL" -H 'Content-Type: application/json' -d "{\"mode\":\"$mode\"}"
echo
