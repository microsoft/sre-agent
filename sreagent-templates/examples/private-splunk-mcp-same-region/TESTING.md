# Testing the private same-region Splunk MCP template

This guide validates the Bicep and Terraform variants independently. Each path deploys the delegated SRE Agent subnet and private Splunk subnet into one regional VNet.

## Test goals

The template passes when:

1. Static validation succeeds.
2. The deployment creates one VNet with two nonoverlapping subnets in the SRE Agent region.
3. The agent subnet is delegated to `Microsoft.App/environments`.
4. The Splunk VM has no public IP and uses NAT only for outbound bootstrap traffic.
5. The existing SRE Agent resolves and reaches the private Splunk hostname.
6. The Splunk connector reports **Connected** and discovers tools.
7. `splunk_get_info` and `splunk_get_indexes` return data.
8. Splunk logs show the connector source inside the delegated agent subnet.

## Recommended matrix

| Infrastructure path | Suggested resource group | Suggested prefix | Suggested CIDRs |
|---|---|---|---|
| Bicep | `rg-splunk-mcp-same-bicep-test` | `splsameb` | `10.110.0.0/16` |
| Terraform | `rg-splunk-mcp-same-tf-test` | `splsametf` | `10.120.0.0/16` |

Use separate CIDRs because only one test environment can be attached to the SRE Agent at a time, but both resource groups may coexist.

## Cost and security notes

- The VM, NAT Gateway, managed disk, and NAT public IP incur charges.
- The Splunk VM has no public IP.
- Do not commit generated parameter files, `terraform.tfvars`, Terraform state, SSH keys, passwords, packages, or MCP tokens.
- The HTTP option is lab-only. Production requires trusted HTTPS.
- Use a disposable SRE Agent or explicitly restore its intended subnet after testing.

## Prerequisites

- Azure CLI authenticated to the target subscription.
- An existing SRE Agent in the selected region.
- Deployment permissions for networking, VM, NAT Gateway, private DNS, managed identities, and temporary storage.
- An SSH public key.
- The Splunk MCP package downloaded from Splunkbase.
- `jq` for Bash or PowerShell 7+ for PowerShell.
- Terraform 1.5+ for Terraform testing.

Confirm the subscription:

```bash
az account show --query "{name:name,id:id,tenant:tenantId,user:user.name}" --output table
```

Confirm the VM SKU:

```bash
az vm list-skus --location eastus2 --resource-type virtualMachines --size Standard_D4as_v5 --all --output table
```

## 1. Run static validation

From `sreagent-templates`:

```bash
bash tests/test-dry-run-private-splunk-same-region.sh
```

Expected:

```text
private-splunk-same-region: PASS
```

## 2A. Deploy Bicep

Copy the example:

```bash
cp examples/private-splunk-mcp-same-region/bicep/main.parameters.json.example examples/private-splunk-mcp-same-region/bicep/main.parameters.json
```

Set a unique prefix, the SRE Agent region, your SSH public key, and nonoverlapping CIDRs.

Bash:

```bash
cd examples/private-splunk-mcp-same-region && ./scripts/deploy.sh bicep --resource-group rg-splunk-mcp-same-bicep-test --parameters bicep/main.parameters.json
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-same-region; ./scripts/Deploy.ps1 -Backend Bicep -ResourceGroup rg-splunk-mcp-same-bicep-test -ParametersFile ./bicep/main.parameters.json
```

Record the `agentSubnetId`, `splunkVmName`, `splunkPrivateIp`, and `splunkPrivateHostname` outputs.

## 2B. Deploy Terraform

Copy the example:

```bash
cp examples/private-splunk-mcp-same-region/terraform/terraform.tfvars.example examples/private-splunk-mcp-same-region/terraform/terraform.tfvars
```

Set a separate resource group, prefix, CIDRs, and SSH public key.

Bash:

```bash
cd examples/private-splunk-mcp-same-region && ./scripts/deploy.sh terraform --tfvars terraform/terraform.tfvars
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-same-region; ./scripts/Deploy.ps1 -Backend Terraform -TfVarsFile ./terraform/terraform.tfvars
```

Record `agent_subnet_id`, `splunk_vm_name`, `splunk_private_ip`, and `splunk_hostname`.

## 3. Inspect infrastructure

Confirm the VM has no public IP:

```bash
az vm show --resource-group "<resource-group>" --name "<vm-name>" --show-details --query "{privateIps:privateIps,publicIps:publicIps,powerState:powerState}" --output json
```

Confirm both subnets are in one VNet:

```bash
az network vnet subnet list --resource-group "<resource-group>" --vnet-name "<vnet-name>" --query "[].{name:name,prefix:addressPrefix,delegations:delegations[].serviceName,nsg:networkSecurityGroup.id,nat:natGateway.id}" --output json
```

Expected:

- `agent-subnet` is `/27` and delegated to `Microsoft.App/environments`.
- `splunk-subnet` has the NSG and NAT Gateway.
- No VNet peering resources are required.

Confirm private DNS:

```bash
az network private-dns record-set a list --resource-group "<resource-group>" --zone-name lab.internal --output table
```

## 4. Attach the SRE Agent

Bash:

```bash
cd examples/private-splunk-mcp-same-region && ./scripts/patch-agent.sh --subscription "<subscription-id>" --resource-group "<agent-resource-group>" --agent-name "<agent-name>" --subnet-id "<agent-subnet-id>"
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-same-region; ./scripts/Patch-Agent.ps1 -SubscriptionId "<subscription-id>" -ResourceGroup "<agent-resource-group>" -AgentName "<agent-name>" -SubnetId "<agent-subnet-id>"
```

If the script reports that the agent is already attached elsewhere, intentionally disconnect or move the disposable test agent before retrying.

Verify:

1. Azure VNet egress is connected to the expected subnet.
2. Private DNS resolution is enabled.
3. Remote MCP infrastructure-network bypass is disabled.

## 5. Install Splunk and MCP

Bash:

```bash
cd examples/private-splunk-mcp-same-region && ./scripts/configure-splunk.sh --resource-group "<resource-group>" --vm-name "<vm-name>" --package "<splunk-package-path>" --enable-lab-http
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-same-region; ./scripts/Configure-Splunk.ps1 -ResourceGroup "<resource-group>" -VmName "<vm-name>" -PackagePath "<splunk-package-path>" -EnableLabHttp
```

The command can take 10-20 minutes.

## 6. Validate DNS and endpoint reachability

In the SRE Agent inspect terminal:

```bash
getent hosts splunk-mcp.lab.internal
```

Expected: the private VM IP.

```bash
curl -v --connect-timeout 15 http://splunk-mcp.lab.internal:8089/services/mcp
```

Expected: HTTP `405 Method Not Allowed`.

## 7. Mint a token

Bash:

```bash
cd examples/private-splunk-mcp-same-region && ./scripts/mint-mcp-token.sh --resource-group "<resource-group>" --vm-name "<vm-name>" --scheme http --days 1
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-same-region; ./scripts/Mint-McpToken.ps1 -ResourceGroup "<resource-group>" -VmName "<vm-name>" -Scheme http -Days 1
```

Store the token securely and do not write it into the template directory.

## 8. Create or update the connector

In `https://sre.azure.com`:

1. Open the test agent.
2. Open **Build + setup > Connectors**.
3. Add or edit the Splunk connector.
4. Use `http://splunk-mcp.lab.internal:8089/services/mcp` for the isolated HTTP lab.
5. Paste the complete encrypted token.
6. Test the connection and confirm 17 tools are discovered.
7. Select the required read-only tools and save.
8. Wait for **Connected**.

## 9. Invoke real tools

Start a new conversation:

```text
Use only the private Splunk connector. Call splunk_get_info and report the version, health, and server identifier. Then call splunk_get_indexes and list the first five index names.
```

Both tool cards must show **Completed**.

## 10. Prove private source routing

```bash
az vm run-command invoke --resource-group "<resource-group>" --name "<vm-name>" --command-id RunShellScript --scripts "sudo docker exec -u 0 splunk sh -c 'grep /services/mcp /opt/splunk/var/log/splunk/splunkd_access.log | grep -v ^127.0.0.1 | tail -n 30'" --query "value[0].message" --output tsv
```

Find entries with:

- `POST /services/mcp`
- HTTP `200` or `202`
- User agent `python-httpx`
- A source IP inside the delegated `/27` agent subnet

Ignore `127.0.0.1` `Python-urllib` entries; those are local health probes.

## 11. Cleanup

Disconnect or move the SRE Agent before deleting its subnet.

Bicep:

```bash
az group delete --name rg-splunk-mcp-same-bicep-test --yes
```

Terraform:

```bash
terraform -chdir=examples/private-splunk-mcp-same-region/terraform destroy -var-file=terraform.tfvars
```

Record the tool results, connector status, Splunk server identifier, private source IP, and cleanup outcome for each deployment path.
