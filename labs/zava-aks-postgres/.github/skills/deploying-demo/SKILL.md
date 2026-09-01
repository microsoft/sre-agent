---
name: deploying-demo
description: Deploy the SRE Agent demo end-to-end. Use when asked to set up, deploy, or get this demo running.
---

# Deploying the Demo

## Prerequisites Check
Run these and install anything missing:
- `az version` — need 2.60+
- `azd version` — need 1.9+
- `pwsh -v` — need 7.4+
- Azure permission: Owner, User Access Administrator, or equivalent
  `Microsoft.Authorization/roleAssignments/write` at subscription scope. The
  template grants the agent runtime identity subscription Reader for correlation
  context and removes it during `azd down`.

> Note: `kubectl` is **not** required on your local workstation. The cluster is private. Operator
> scripts in this repo go through `az aks command invoke` (wrapped by `scripts/_aks-helpers.ps1`).
> The SRE Agent uses its built-in `RunKubectlReadCommand` and `RunKubectlWriteCommand` tools instead.

## Phase 1: Azure Deployment
1. Check if user has a subscription: `az account show`
2. Set azd environment: `azd env set AZURE_SUBSCRIPTION_ID <sub-id>` and `azd env set AZURE_LOCATION swedencentral`
3. Run `azd up --no-prompt`
4. Wait for completion (~25 min). Monitor progress. The post-provision hook
   handles image build, k8s manifest apply (via command invoke), workload
   identity federation, and SRE Agent data-plane sync.

## Phase 2: Verify Deployment
The AKS API server is private (`enablePrivateCluster: true`) — local kubectl
will not work. Human operators use the Azure-proxied command-invoke path:

```powershell
. .\scripts\_aks-helpers.ps1
$ctx = Resolve-AksContext
$r = Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName `
    -Command "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" -Quiet
$ip = ($r.logs -replace '[^\d\.]','').Trim()
"Storefront: http://$ip"
```

1. Open `http://<ip>/` in a browser — verify products load, status shows healthy.
2. Hit the health endpoint from your local workstation: `Invoke-RestMethod "http://<ip>/api/health"`
   (the storefront LoadBalancer IP is public; only the cluster API server is private).
3. If the LB IP is not reachable from your machine (corporate VPN, etc.), verify
   from inside the cluster instead:
   ```powershell
   Invoke-AksCommand -ResourceGroup $ctx.ResourceGroup -ClusterName $ctx.ClusterName `
       -Command "kubectl exec -n zava-demo deploy/zava-api -- wget -qO- http://localhost:3001/api/health"
   ```

> For SRE Agent operations, use the built-in `RunKubectlReadCommand` and
> `RunKubectlWriteCommand` tools. See `docs/aks-access-and-auth.md` for other
> operator and automation access options.

## Phase 3: Configure + verify SRE Agent

Bicep provisions the agent, supported connectors, autonomous mode, and Azure
Monitor binding. The setup script applies custom skills and response plans
from the repository, uploads knowledge files, syncs global instructions,
enables the Microsoft Learn tools, and verifies the result.

`azd up` runs `setup-sre-agent.ps1` through the post-provision hook. Run it
manually only to retry or apply later configuration changes:

1. Get azd values: `$env:SRE_AGENT_ENDPOINT = azd env get-value SRE_AGENT_ENDPOINT` (and RESOURCE_GROUP, SRE_AGENT_NAME)
2. Run: `.\scripts\setup-sre-agent.ps1` (auto-detects ResourceGroup and AgentName from `azd env`)
3. If Step 7 reports a missing skill or response plan, re-run
   `setup-sre-agent.ps1`. If a connector or core agent setting is missing,
   re-run `azd provision`.

## Optional: confirm the agent is reachable

Sanity-check the agent's data-plane API before running break/fix scenarios:
```powershell
.\scripts\watch-agent.ps1     # lists incident threads (empty on a fresh deploy is fine)
```
This is the same script the running-demo skill uses to tail the agent live during scenarios.

## Teardown
`azd down --force --purge`
