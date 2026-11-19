#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

kubectl create namespace sre-demo --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$SCRIPT_DIR/sample-app.yaml"
kubectl apply -f "$SCRIPT_DIR/load-generator.yaml"
kubectl apply -f "$SCRIPT_DIR/ama-metrics-settings-configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/sample-app-servicemonitor.yaml"

kubectl rollout status deployment/sample-app -n sre-demo --timeout=120s
kubectl rollout status deployment/load-generator -n sre-demo --timeout=120s

echo
echo "Lab resources:"
kubectl get pods,svc -n sre-demo
echo
kubectl get servicemonitor -n sre-demo
