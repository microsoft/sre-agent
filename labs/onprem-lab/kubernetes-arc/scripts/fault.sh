#!/bin/bash
set -e
NAMESPACE="sre-demo"
POD=$(kubectl get pod -n "$NAMESPACE" -l app=sample-app -o jsonpath='{.items[0].metadata.name}')
case "$1" in
  fail)
    echo "Injecting HTTP 500 failures into $POD"
    kubectl exec -n "$NAMESPACE" "$POD" -- touch /fault/fail
    ;;
  reset)
    echo "Resetting $POD"
    kubectl exec -n "$NAMESPACE" "$POD" -- rm -f /fault/fail
    ;;
  *)
    echo "Usage: $0 {fail|reset}"
    exit 1
    ;;
esac
