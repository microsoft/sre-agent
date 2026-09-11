# Private cross-region Splunk MCP lab

> **Validation status:** The Bicep deployment path, private DNS, Global VNet Peering, Splunk Enterprise container, official MCP app installation, encrypted token creation, SRE Agent connector, tool discovery, and read-only tool invocation were validated end to end on September 10, 2026. Both infrastructure definitions pass offline compilation and validation; use [TESTING.md](TESTING.md) to validate either deployment path in your subscription.

This example shows how an Azure SRE Agent in one region can reach a private Splunk Enterprise MCP endpoint in another region without exposing Splunk to inbound internet traffic.

The default regions are:

- SRE Agent and delegated subnet: **East US 2**
- Private Splunk VM: **Central US**

Central US is only the default because the test subscription had no deployable general-purpose VM capacity in East US. Changing the Splunk region does not change the routing mechanism: private traffic still crosses Microsoft’s backbone through Global VNet Peering.

## Architecture

```text
Existing SRE Agent (East US 2)
  |
  | AzureVNet egress; remote MCP infra-network bypass disabled
  v
Delegated agent subnet 10.20.0.0/27
  |
  | Global VNet Peering
  v
Private Splunk subnet 10.40.1.0/24 (Central US)
  |
  +-- NSG: allow 10.20.0.0/27 to TCP 8080 and 8089
  +-- NSG: deny all other VirtualNetwork and Internet inbound traffic
  +-- NAT Gateway: outbound-only package and image downloads
  |
  v
Private Ubuntu VM 10.40.1.4 (no public IP)
  +-- Nginx connectivity probe: TCP 8080
  +-- Splunk Web: TCP 8000, not allowed across the peering by default
  +-- Splunk MCP: TCP 8089 /services/mcp
```

## What this example deploys

| Resource | Purpose |
|---|---|
| Agent VNet and `/27` subnet | Same-region network attachment for the existing SRE Agent |
| `Microsoft.App/environments` delegation | Allows the SRE Agent managed environment to use the dedicated subnet |
| Splunk VNet and `/24` subnet | Private network for the Splunk VM |
| Two VNet peerings | Direct private connectivity across Azure regions |
| NSG | Allows only the agent subnet to reach the test and MCP ports |
| NAT Gateway and public IP | Outbound-only bootstrap access; no inbound public endpoint |
| Private DNS zone | Resolves `splunk-mcp.lab.internal` from both VNets |
| Ubuntu VM | Docker host for a standalone, nonproduction Splunk Enterprise lab |

The infrastructure templates do **not** contain a Splunk password, MCP token, Splunkbase package, or connector credential.

## Important boundaries

- This is a lab and starting point, not a production Splunk architecture.
- The standalone Splunk container stores its data on Docker volumes backed by the VM OS disk.
- The official MCP app package is not redistributed. Download it directly from [Splunkbase app 7931](https://splunkbase.splunk.com/app/7931).
- Review and accept the [Splunk General Terms](https://www.splunk.com/en_us/legal/splunk-general-terms.html) before running the setup script.
- Production should use a certificate trusted by the SRE Agent runtime.
- `--enable-lab-http` disables TLS only on the private Splunk management endpoint. It is an explicit, lab-only workaround for testing when the private CA cannot be added to the SRE Agent trust store.
- The setup scripts pass secrets to Azure CLI as protected VM Run Command parameters. They are not stored in ARM outputs or Terraform state, but can be transiently visible to administrators inspecting processes on the operator workstation while the command starts.

## Prerequisites

- An existing SRE Agent in a supported Azure region.
- Contributor or equivalent deployment permissions for the lab resource group, including permission to list keys for the temporary storage account created by the setup script.
- Azure CLI and `jq` for Bash, or Azure CLI and PowerShell 7+ for PowerShell.
- Terraform 1.5+ when using Terraform.
- An SSH public key.
- A downloaded MCP Server for Splunk Platform `.tgz` or `.spl` package.
- VM quota and SKU availability in the selected Splunk region.

Check a candidate VM size before deployment:

```bash
az vm list-skus --location centralus --resource-type virtualMachines --size Standard_D4as_v5 --all --output table
```

## Deploy with Bicep

Copy and edit the example parameters:

```bash
cp bicep/main.parameters.json.example bicep/main.parameters.json
```

Bash:

```bash
./scripts/deploy.sh bicep --resource-group rg-private-splunk-lab --parameters bicep/main.parameters.json
```

PowerShell:

```powershell
./scripts/Deploy.ps1 -Backend Bicep -ResourceGroup rg-private-splunk-lab -ParametersFile ./bicep/main.parameters.json
```

Both deploy scripts validate the regions and SSH public key before creating resources. This prevents a same-region deployment from silently defeating the cross-region purpose of the lab.

## Deploy with Terraform

Copy and edit the example variables:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Bash:

```bash
./scripts/deploy.sh terraform --tfvars terraform/terraform.tfvars
```

PowerShell:

```powershell
./scripts/Deploy.ps1 -Backend Terraform -TfVarsFile ./terraform/terraform.tfvars
```

## Attach the existing SRE Agent

Use the Bicep `agentSubnetId` output or Terraform `agent_subnet_id` output.

Bash:

```bash
./scripts/patch-agent.sh --subscription "<subscription-id>" --resource-group "<agent-resource-group>" --agent-name "<agent-name>" --subnet-id "<agent-subnet-resource-id>"
```

PowerShell:

```powershell
./scripts/Patch-Agent.ps1 -SubscriptionId "<subscription-id>" -ResourceGroup "<agent-resource-group>" -AgentName "<agent-name>" -SubnetId "<agent-subnet-resource-id>"
```

The patch script:

1. Confirms the agent and delegated VNet are in the same region.
2. Refuses to silently move an agent already attached to a different subnet.
3. Selects `AzureVNet` egress.
4. Enables private DNS resolution.
5. Disables remote HTTP MCP access through the SRE Agent infrastructure network.

## Install Splunk and the MCP app

The setup script prompts for the Splunk administrator password and passes secrets using protected Azure VM Run Command parameters. It creates a temporary storage account in the lab resource group, uploads the package with the account key, issues a one-hour read-only service SAS, installs Docker and Splunk, installs the user-provided MCP package as the `splunk` OS user, and deletes the temporary storage account.

Bash with trusted HTTPS:

```bash
./scripts/configure-splunk.sh --resource-group rg-private-splunk-lab --vm-name sre-splunk-vm --package ~/splunk-mcp-server.tgz
```

PowerShell with trusted HTTPS:

```powershell
./scripts/Configure-Splunk.ps1 -ResourceGroup rg-private-splunk-lab -VmName sre-splunk-vm -PackagePath ./splunk-mcp-server.tgz
```

For the isolated lab-only HTTP workaround:

```bash
./scripts/configure-splunk.sh --resource-group rg-private-splunk-lab --vm-name sre-splunk-vm --package ~/splunk-mcp-server.tgz --enable-lab-http
```

```powershell
./scripts/Configure-Splunk.ps1 -ResourceGroup rg-private-splunk-lab -VmName sre-splunk-vm -PackagePath ./splunk-mcp-server.tgz -EnableLabHttp
```

If Docker Hub throttles the image pull, import `splunk/splunk:latest` into an Azure Container Registry, enable its admin account temporarily, and pass `--acr-name <name>` or `-AcrName <name>`. Disable the ACR admin account after installation.

## Validate private routing

From an SRE Agent conversation, run:

```text
Use the terminal to run: getent hosts splunk-mcp.lab.internal && curl -v --connect-timeout 15 http://splunk-mcp.lab.internal:8080
```

Expected:

- DNS resolves to the configured private VM IP.
- TCP connection succeeds across Global VNet Peering.
- Nginx returns HTTP `200`.

For trusted HTTPS, probe Splunk:

```text
Use the terminal to run: curl -v --connect-timeout 15 https://splunk-mcp.lab.internal:8089/services/server/info
```

An HTTP `401` is expected without credentials and proves the request reached Splunk. Do not use `curl -k` as the final production validation because it bypasses certificate verification.

## Mint an encrypted MCP token

Bash:

```bash
./scripts/mint-mcp-token.sh --resource-group rg-private-splunk-lab --vm-name sre-splunk-vm --scheme https --days 7
```

PowerShell:

```powershell
./scripts/Mint-McpToken.ps1 -ResourceGroup rg-private-splunk-lab -VmName sre-splunk-vm -Scheme https -Days 7
```

For the explicit lab HTTP mode, replace `https` with `http`. The script displays the encrypted token once, deletes the managed run-command resource, and does not write the token to a repository file or Terraform state. Store the token in an approved secret store.

## Configure the SRE Agent Splunk connector

In the SRE Agent portal:

1. Open **Build + setup > Connectors**.
2. Add the **Splunk** partner MCP connector.
3. Set the endpoint to `https://splunk-mcp.lab.internal:8089/services/mcp`, or `http://...` only for the explicit isolated-lab mode.
4. Paste the encrypted MCP token.
5. Select the read-only tools needed for the test.
6. Save and wait for the connector to report **Connected**.

## Final validation

Ask the agent:

```text
Use the Splunk connector to return the Splunk server version, list the available indexes, and run a read-only search over index=_internal for the last 15 minutes.
```

Success requires:

- The connector reports **Connected**.
- MCP tools are discovered.
- A tool invocation returns data from the private Splunk instance.
- Splunk access logs show authenticated requests from the delegated SRE Agent subnet.
- Disabling peering or denying TCP 8089 causes the connector invocation to fail.

The validated lab returned:

- Splunk Enterprise `10.4.3`, build `4174a2deda5d`, with green health.
- 17 MCP tools discovered.
- 16 indexes returned by `splunk_get_indexes`.
- HTTP `200` entries in `splunkd_access.log` from `10.20.0.9`, an address in the delegated `10.20.0.0/27` agent subnet.

The live connector used the explicit lab-only HTTP mode because Splunk's default self-signed certificate failed the SRE Agent connector's certificate validation. The HTTPS failure reached the private hostname and failed with `CERTIFICATE_VERIFY_FAILED`, confirming that routing was working and certificate trust was the only HTTPS blocker. Use a publicly trusted or organization-trusted certificate for production.

### Common validation failures

| Symptom | Likely cause | Resolution |
|---|---|---|
| `CERTIFICATE_VERIFY_FAILED` | Splunk is using its default self-signed certificate | Install a certificate trusted by the SRE Agent runtime, or use the explicit lab-only HTTP mode |
| HTTP `401` from `/services/mcp` | Missing, expired, truncated, or plaintext token | Mint a new encrypted token and paste the entire value; the validated encrypted token had two dot-separated segments |
| Hostname doesn't resolve | Private DNS zone or VNet link is missing | Link the zone to both VNets with registration disabled and verify the explicit A record |
| Connection times out | Peering, NSG, route, or return path is missing | Verify both peering directions and allow the agent subnet to TCP 8089 |

## Customer topology

For a customer with private Splunk outside Azure, replace the lab Splunk VM with the existing private destination:

```text
SRE Agent subnet in the agent region
  -> Global VNet Peering, Virtual WAN, or hub connectivity
  -> Customer management network
  -> VPN, ExpressRoute, or private WAN route
  -> Private Splunk MCP endpoint
```

The exact customer route may additionally require gateway transit, an NVA, custom route tables, and a return route for the agent subnet. VNet peering itself is not transitive.

## Cleanup

Bicep deployments are removed by deleting the dedicated lab resource group:

```bash
az group delete --name rg-private-splunk-lab --yes
```

Terraform:

```bash
terraform -chdir=terraform destroy -var-file=terraform.tfvars
```

The SRE Agent keeps its subnet reference after the infrastructure is deleted. Before cleanup, either restore the agent’s intended network configuration or delete the disposable lab agent.

## References

- [Azure SRE Agent network integration](https://learn.microsoft.com/azure/sre-agent/network-integration)
- [Azure SRE Agent MCP connectors](https://learn.microsoft.com/azure/sre-agent/mcp-connectors)
- [MCP Server for Splunk Platform](https://splunkbase.splunk.com/app/7931)
- [Docker-Splunk advanced configuration](https://github.com/splunk/docker-splunk/blob/develop/docs/ADVANCED.md)
- [Global VNet Peering](https://learn.microsoft.com/azure/virtual-network/virtual-network-peering-overview)
