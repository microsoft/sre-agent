#!/bin/bash
# Quick Deploy - SRE Agent Without Target Resource Groups
# This script deploys a standalone SRE Agent

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "🚀 Quick Deploy: SRE Agent (No Target Resource Groups)"
echo "========================================================"
echo ""

# Check if Azure CLI is installed and user is logged in
if ! command -v az &> /dev/null; then
    echo "❌ Azure CLI is not installed. Please install it first."
    exit 1
fi

if ! az account show &>/dev/null; then
    echo "❌ Not logged in to Azure. Please run 'az login' first."
    exit 1
fi

# Get current subscription
CURRENT_SUB=$(az account show --query 'id' -o tsv)
CURRENT_SUB_NAME=$(az account show --query 'name' -o tsv)

echo "✅ Current Subscription: $CURRENT_SUB_NAME"
echo "   ID: $CURRENT_SUB"
echo ""

# Prompt for basic info
read -p "Resource Group Name [rg-sre-agent]: " RG_NAME
RG_NAME=${RG_NAME:-rg-sre-agent}

read -p "Agent Name [sre-agent-$(date +%Y%m%d)]: " AGENT_NAME
AGENT_NAME=${AGENT_NAME:-sre-agent-$(date +%Y%m%d)}

read -p "Location [eastus2]: " LOCATION
LOCATION=${LOCATION:-eastus2}

read -p "Access Level (High/Low) [High]: " ACCESS_LEVEL
ACCESS_LEVEL=${ACCESS_LEVEL:-High}

echo ""
echo "📋 Deployment Configuration:"
echo "   Subscription: $CURRENT_SUB"
echo "   Resource Group: $RG_NAME"
echo "   Agent Name: $AGENT_NAME"
echo "   Location: $LOCATION"
echo "   Access Level: $ACCESS_LEVEL"
echo "   Target Resource Groups: NONE (standalone deployment)"
echo ""

read -p "Proceed with deployment? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Deployment cancelled."
    exit 1
fi

echo ""
echo "🔨 Creating resource group..."
az group create --name "$RG_NAME" --location "$LOCATION" --subscription "$CURRENT_SUB"

echo ""
echo "🚀 Starting deployment..."
DEPLOYMENT_NAME="sre-agent-deployment-$(date +%Y%m%d-%H%M%S)"

az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --template-file "$PROJECT_ROOT/bicep/minimal-sre-agent.bicep" \
  --parameters \
    agentName="$AGENT_NAME" \
    subscriptionId="$CURRENT_SUB" \
    deploymentResourceGroupName="$RG_NAME" \
    location="$LOCATION" \
    accessLevel="$ACCESS_LEVEL" \
    targetResourceGroups='[]'

echo ""
echo "✅ Deployment completed successfully!"
echo ""
echo "📊 Deployment Outputs:"
az deployment sub show --name "$DEPLOYMENT_NAME" --query 'properties.outputs' -o table

echo ""
echo "🎉 Your SRE Agent is ready!"
echo ""
echo "Next steps:"
echo "1. Access the agent portal (see agentPortalUrl above)"
echo "2. Install SRECTL tool: dotnet tool install sreagent.cli --global"
echo "3. Configure sub-agents (see SRECTL-guide-v2.md)"
echo "4. Optional: Add target resource groups later via redeployment"
