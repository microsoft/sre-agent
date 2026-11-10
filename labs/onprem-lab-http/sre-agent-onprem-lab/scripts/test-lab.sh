#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Healthy response:"; curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/api/orders
./scripts/fault.sh http500
sleep 6
echo "Faulted response:"; code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/api/orders); echo "HTTP $code"
./scripts/fault.sh reset
sleep 1
echo "Recovered response:"; curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080/api/orders
echo "Recent application log:"; tail -n 8 /var/log/sre-lab/app.log
