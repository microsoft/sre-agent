# Octopets Application Setup

This guide walks you through deploying the Octopets sample application with error generation capabilities. Complete this setup before following the [Getting Started Guide](./GettingStarted.md) to ensure you have a working application for incident automation testing.

## Prerequisites

- Azure subscription
- Azure Developer CLI (azd) installed
- .NET 9 SDK installed
- Docker Desktop running
- Git installed

## Step 1: Deploy Octopets Application

### 1.1 Clone the Repository

```bash
git clone https://github.com/Azure-Samples/octopets
cd octopets
```

### 1.2 Generate Bicep Files

```bash
azd infra generate
```

This generates the infrastructure-as-code files needed for deployment.

### 1.3 Deploy to Azure

```bash
azd up
```

Follow the prompts:
- Select your Azure subscription
- Choose a region (e.g., East US 2)
- Provide an environment name (e.g., "octopets-demo")

The deployment will create:
- Azure Container Apps for frontend (octopetsfe) and backend (octopetsapi)
- Azure Container Registry
- Log Analytics Workspace
- Application Insights
- Resource group containing all resources

**Make note of:**
- Subscription ID
- Resource group name
- Frontend URL
- Backend Container App name (octopetsapi)

### 1.4 Verify Deployment

1. Navigate to Azure Portal
2. Find your resource group
3. Open the frontend Container App (octopetsfe)
4. Click on the Application URL to open Octopets in your browser
5. Verify the application loads correctly

## Step 2: Configure Application to Generate Errors

### 2.1 Configure Frontend Settings

1. In Azure Portal, navigate to your frontend Container App (octopetsfe)
2. Go to **Containers** → **Edit and deploy**
3. Find or add the environment variable:
   - **Name**: `REACT_APP_USE_MOCK_DATA`
   - **Value**: `false`
4. Click **Save** and wait for the revision to deploy

### 2.2 Enable Error Generation in Backend

1. Navigate to your backend Container App (octopetsapi)
2. Go to **Containers** → **Edit and deploy**
3. Find or add the environment variable:
   - **Name**: `Errors`
   - **Value**: `true`
4. Click **Save** and wait for the revision to deploy

**What this does:** Setting `Errors` to `true` activates code that intentionally consumes excessive memory, simulating a memory leak scenario.

## Step 3: Upload Code to Your GitHub Repository

To enable SRE Agent to analyze your code and create issues:

1. Create a new repository in your GitHub account (e.g., "octopets-demo")
2. Add your GitHub remote:

```bash
git remote add myrepo https://github.com/YOUR_USERNAME/octopets-demo.git
```

3. Push the code:

```bash
git push myrepo main
```

4. Make note of your repository URL for connecting to SRE Agent

## Next Steps

Now that your Octopets application is deployed and configured:

1. Follow the [Configure SRE Agent Guide](../00-configure-sre-agent.md) to set up Azure SRE Agent with incident platform, Outlook, and GitHub connectors
2. Then proceed to the [Octopets Memory Leak Sample](../01-octopets-memleak-sample.md) to test incident automation

## Resources

- [Octopets GitHub Repository](https://github.com/Azure-Samples/octopets)
- [Azure Container Apps Documentation](https://learn.microsoft.com/azure/container-apps/)
- [Azure Developer CLI Documentation](https://learn.microsoft.com/azure/developer/azure-developer-cli/)
