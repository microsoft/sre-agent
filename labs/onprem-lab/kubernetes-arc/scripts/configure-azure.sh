#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --subscription-id ID --resource-group NAME --region REGION [--cluster-name NAME] [--workspace-name NAME]"
}

SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
REGION=""
CLUSTER_NAME="$(hostname | tr '[:upper:]' '[:lower:]')"
WORKSPACE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --workspace-name) WORKSPACE_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$SUBSCRIPTION_ID" || -z "$RESOURCE_GROUP" || -z "$REGION" ]]; then
  usage
  exit 1
fi

WORKSPACE_NAME="${WORKSPACE_NAME:-${CLUSTER_NAME}-amw}"

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required." >&2; exit 1; }

if ! az account show >/dev/null 2>&1; then
  az login
fi

az account set --subscription "$SUBSCRIPTION_ID"

providers=(
  Microsoft.Kubernetes
  Microsoft.KubernetesConfiguration
  Microsoft.ExtendedLocation
  Microsoft.Insights
  Microsoft.Monitor
  Microsoft.AlertsManagement
  Microsoft.OperationalInsights
  Microsoft.Dashboard
)

for provider in "${providers[@]}"; do
  echo "Registering $provider..."
  az provider register --namespace "$provider" --wait
 done

az extension add --name connectedk8s --upgrade --yes
az extension add --name k8s-extension --upgrade --yes

az group create --name "$RESOURCE_GROUP" --location "$REGION" --output none

if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Arc-enabled cluster $CLUSTER_NAME already exists."
else
  az connectedk8s connect \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$REGION" \
    --yes
fi

if az monitor account show --name "$WORKSPACE_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  echo "Azure Monitor workspace $WORKSPACE_NAME already exists."
else
  az monitor account create \
    --name "$WORKSPACE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$REGION" \
    --output none
fi

WORKSPACE_ID=$(az monitor account show \
  --name "$WORKSPACE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

if az k8s-extension show \
  --name azuremonitor-metrics \
  --cluster-type connectedClusters \
  --cluster-name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
  az k8s-extension update \
    --name azuremonitor-metrics \
    --cluster-type connectedClusters \
    --cluster-name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --configuration-settings "azure-monitor-workspace-resource-id=$WORKSPACE_ID" \
    --output none
else
  az k8s-extension create \
    --name azuremonitor-metrics \
    --extension-type Microsoft.AzureMonitor.Containers.Metrics \
    --cluster-type connectedClusters \
    --cluster-name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --configuration-settings "azure-monitor-workspace-resource-id=$WORKSPACE_ID" \
    --release-train stable \
    --auto-upgrade-minor-version true \
    --output none
fi

echo
echo "Azure Arc and Managed Prometheus configuration completed."
echo "Cluster:   $CLUSTER_NAME"
echo "Workspace: $WORKSPACE_NAME"
az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --query connectivityStatus -o tsv
az k8s-extension show --name azuremonitor-metrics --cluster-type connectedClusters --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --query provisioningState -o tsv
