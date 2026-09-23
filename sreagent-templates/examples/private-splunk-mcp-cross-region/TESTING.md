# Testing the private cross-region Splunk MCP template

This guide provides a repeatable test plan for the Bicep and Terraform versions of the private Splunk MCP lab. Run each infrastructure path in a separate resource group so the results are independent.

## Test goals

The template passes when:

1. Static validation succeeds for the infrastructure and scripts.
2. The selected infrastructure template deploys without a public IP on the Splunk VM.
3. The SRE Agent resolves the private Splunk hostname and reaches it through Global VNet Peering.
4. The Splunk partner MCP connector reports **Connected** and discovers tools.
5. `splunk_get_info` and `splunk_get_indexes` return data.
6. Splunk records the connector request from an IP in the delegated SRE Agent subnet.
7. All test resources can be cleaned up without leaving the agent attached to a deleted subnet.

## Recommended test matrix

| Tester | Infrastructure path | Suggested resource group | Suggested name prefix |
|---|---|---|---|
| You | Bicep | `rg-splunk-mcp-bicep-test` | `splunk-bicep` |
| Manager | Terraform | `rg-splunk-mcp-tf-test` | `splunk-tf` |

Use different CIDR ranges if both tests run in the same subscription at the same time.

## Important cost and security notes

- The Splunk VM, NAT Gateway, managed disk, and NAT public IP incur charges.
- Deallocating the VM stops VM compute charges, but the disk, NAT Gateway, and public IP continue to incur charges.
- Delete the test resource group or run `terraform destroy` after testing.
- Do not commit `terraform.tfvars`, generated parameter files, Terraform state, the Splunk package, passwords, or MCP tokens.
- The HTTP option in this guide is only for the isolated private lab. Production must use HTTPS with a certificate trusted by SRE Agent.
- Use a disposable SRE Agent or an agent that is not already attached to another subnet. The patch scripts refuse to move an existing VNet attachment.

## Prerequisites

Each tester needs:

- Azure CLI authenticated to the target subscription.
- Permission to deploy networking, a VM, a NAT Gateway, private DNS, and managed identities.
- An existing SRE Agent in the same region as the new delegated agent subnet.
- An SSH public key.
- The MCP Server for Splunk Platform package downloaded directly from [Splunkbase](https://splunkbase.splunk.com/app/7931).
- `jq` when using Bash.
- PowerShell 7+ when using the PowerShell scripts.
- Terraform 1.5+ for the Terraform path.
- Contributor or equivalent deployment permissions for the lab resource group, including permission to list keys for the temporary storage account created by the setup script.

Confirm the active Azure subscription:

```bash
az account show --query "{name:name,id:id,tenant:tenantId,user:user.name}" --output table
```

Confirm the default VM SKU is available:

```bash
az vm list-skus --location centralus --resource-type virtualMachines --size Standard_D4as_v5 --all --output table
```

## 1. Extract the package

Extract the supplied ZIP and open a terminal at its `sreagent-templates` directory.

Expected files:

```text
examples/private-splunk-mcp-cross-region/
  bicep/
  terraform/
  scripts/
  README.md
  TESTING.md
tests/test-dry-run-private-splunk-cross-region.sh
```

## 2. Run static validation

### Bash

From the `sreagent-templates` directory:

```bash
bash tests/test-dry-run-private-splunk-cross-region.sh
```

Expected final line:

```text
private-splunk-cross-region: PASS
```

### PowerShell-only workstation

Compile the Bicep template:

```powershell
az bicep build --file ./examples/private-splunk-mcp-cross-region/bicep/main.bicep --outfile "$env:TEMP/private-splunk-main.json"
```

Validate Terraform:

```powershell
terraform -chdir=./examples/private-splunk-mcp-cross-region/terraform fmt -check
```

```powershell
terraform -chdir=./examples/private-splunk-mcp-cross-region/terraform init -backend=false -input=false
```

```powershell
terraform -chdir=./examples/private-splunk-mcp-cross-region/terraform validate
```

Parse every PowerShell script:

```powershell
Get-ChildItem ./examples/private-splunk-mcp-cross-region/scripts/*.ps1 | ForEach-Object { $tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) > $null; if ($errors.Count) { $errors; throw "PowerShell parsing failed for $($_.Name)" } }
```

## 3A. Deploy and test the Bicep version

Copy the example parameters:

```bash
cp examples/private-splunk-mcp-cross-region/bicep/main.parameters.json.example examples/private-splunk-mcp-cross-region/bicep/main.parameters.json
```

Edit `main.parameters.json` and set:

- A unique `namePrefix`.
- The SRE Agent region in `agentLocation`.
- A deployable Splunk region in `splunkLocation`.
- Your SSH public key in `adminSshPublicKey`.
- Nonoverlapping VNet and subnet ranges if the defaults conflict with existing networks.

Deploy with Bash:

```bash
cd examples/private-splunk-mcp-cross-region && ./scripts/deploy.sh bicep --resource-group rg-splunk-mcp-bicep-test --parameters bicep/main.parameters.json
```

Or deploy with PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-cross-region; ./scripts/Deploy.ps1 -Backend Bicep -ResourceGroup rg-splunk-mcp-bicep-test -ParametersFile ./bicep/main.parameters.json
```

Capture the deployment outputs:

```bash
az deployment group show --resource-group rg-splunk-mcp-bicep-test --name "$(az deployment group list --resource-group rg-splunk-mcp-bicep-test --query 'sort_by(@,&properties.timestamp)[-1].name' --output tsv)" --query properties.outputs --output json
```

Record `agentSubnetId`, `splunkVmName`, `splunkPrivateIp`, and `splunkPrivateHostname`.

## 3B. Deploy and test the Terraform version

Do this in a different resource group from the Bicep test.

Copy the example variables:

```bash
cp examples/private-splunk-mcp-cross-region/terraform/terraform.tfvars.example examples/private-splunk-mcp-cross-region/terraform/terraform.tfvars
```

Edit `terraform.tfvars` and set:

- `resource_group_name = "rg-splunk-mcp-tf-test"`
- A unique `name_prefix`.
- The SRE Agent and Splunk regions.
- Your SSH public key.
- Nonoverlapping network ranges.

Deploy with Bash:

```bash
cd examples/private-splunk-mcp-cross-region && ./scripts/deploy.sh terraform --tfvars terraform/terraform.tfvars
```

Or deploy with PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-cross-region; ./scripts/Deploy.ps1 -Backend Terraform -TfVarsFile ./terraform/terraform.tfvars
```

Display the outputs:

```bash
terraform -chdir=examples/private-splunk-mcp-cross-region/terraform output
```

Record `agent_subnet_id`, `splunk_vm_name`, `splunk_private_ip`, and `splunk_hostname`.

## 4. Inspect the deployed infrastructure

Confirm the Splunk VM has no public IP:

```bash
az vm show --resource-group "<lab-resource-group>" --name "<splunk-vm-name>" --show-details --query "{privateIps:privateIps,publicIps:publicIps,powerState:powerState}" --output json
```

Expected: `publicIps` is empty.

Confirm the agent subnet delegation:

```bash
az network vnet subnet show --ids "<agent-subnet-resource-id>" --query "{prefix:addressPrefix,delegations:delegations[].serviceName}" --output json
```

Expected delegation:

```text
Microsoft.App/environments
```

Confirm both VNet peerings report `Connected`:

```bash
az network vnet peering list --resource-group "<lab-resource-group>" --vnet-name "<agent-vnet-name>" --query "[].{name:name,state:peeringState,remote:remoteVirtualNetwork.id}" --output table
```

```bash
az network vnet peering list --resource-group "<lab-resource-group>" --vnet-name "<splunk-vnet-name>" --query "[].{name:name,state:peeringState,remote:remoteVirtualNetwork.id}" --output table
```

## 5. Attach the SRE Agent

Use the `agentSubnetId` or `agent_subnet_id` output.

Bash:

```bash
cd examples/private-splunk-mcp-cross-region && ./scripts/patch-agent.sh --subscription "<subscription-id>" --resource-group "<agent-resource-group>" --agent-name "<agent-name>" --subnet-id "<agent-subnet-resource-id>"
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-cross-region; ./scripts/Patch-Agent.ps1 -SubscriptionId "<subscription-id>" -ResourceGroup "<agent-resource-group>" -AgentName "<agent-name>" -SubnetId "<agent-subnet-resource-id>"
```

In the SRE Agent portal, verify:

1. Open **Settings > Workspace configuration > Networking**.
2. Confirm **Azure VNet — Connected**.
3. Confirm the expected subnet.
4. Confirm **Use VNet's private DNS for resolution**.
5. Turn **Remote MCP server access** off.
6. Save the configuration.

## 6. Install Splunk and the MCP app

The validated lab used HTTP because the disposable Splunk container had a self-signed certificate. Use `--enable-lab-http` or `-EnableLabHttp` only for this isolated test.

Bash:

```bash
cd examples/private-splunk-mcp-cross-region && ./scripts/configure-splunk.sh --resource-group "<lab-resource-group>" --vm-name "<splunk-vm-name>" --package "<path-to-downloaded-splunk-mcp-package>" --enable-lab-http
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-cross-region; ./scripts/Configure-Splunk.ps1 -ResourceGroup "<lab-resource-group>" -VmName "<splunk-vm-name>" -PackagePath "<path-to-downloaded-splunk-mcp-package>" -EnableLabHttp
```

Enter a strong disposable Splunk administrator password when prompted. The operation can take 10–20 minutes while Docker images are downloaded and Splunk starts.

The scripts transport the multiline guest script as base64, read named Linux Managed Run Command parameters from environment variables, and fail when the guest `instanceView.exitCode` is nonzero. This prevents a successful ARM provisioning state from masking a failed installation.

## 7. Validate private DNS and TCP connectivity

In SRE Agent, open **Settings > Workspace configuration > Inspect** and run:

```bash
getent hosts splunk-mcp.lab.internal
```

Expected: the configured private VM IP, such as `10.40.1.4`.

Test the endpoint:

```bash
curl -v --connect-timeout 15 http://splunk-mcp.lab.internal:8089/services/mcp
```

Expected: connection to the private IP followed by HTTP `405 Method Not Allowed`. The `405` is correct because this command sends `GET` while MCP uses authenticated JSON-RPC `POST`.

## 8. Mint an encrypted MCP token

Bash:

```bash
cd examples/private-splunk-mcp-cross-region && ./scripts/mint-mcp-token.sh --resource-group "<lab-resource-group>" --vm-name "<splunk-vm-name>" --scheme http --days 1
```

PowerShell:

```powershell
Set-Location ./examples/private-splunk-mcp-cross-region; ./scripts/Mint-McpToken.ps1 -ResourceGroup "<lab-resource-group>" -VmName "<splunk-vm-name>" -Scheme http -Days 1
```

Copy the displayed token immediately into an approved password manager or secret store. Do not save it in the extracted template directory.

## 9. Create and test the Splunk connector

In `https://sre.azure.com`:

1. Open the test agent.
2. Navigate to **Build + setup > Connectors**.
3. Select **Add connector**.
4. Select **Splunk**.
5. Use a unique name such as `private-splunk-bicep-test`.
6. Set the URL to `http://splunk-mcp.lab.internal:8089/services/mcp`.
7. Paste the complete encrypted token.
8. Select **Test connection**.
9. Confirm that the tool-selection page displays the Splunk MCP tools.
10. Select the desired read-only tools and add the connector.
11. Refresh until its status is **Connected**.

If the connection returns HTTP `401`, verify that the entire encrypted token was pasted. The validated token contained two dot-separated segments.

## 10. Invoke tools through SRE Agent

Start a new SRE Agent chat and enter:

```text
Use only the private Splunk test connector. Call splunk_get_info and report the Splunk version. Then call splunk_get_indexes and list the first five index names.
```

Expected:

- Both tool cards show **Completed**.
- Splunk version and health information are returned.
- A nonempty list of indexes is returned.

## 11. Prove that connector traffic used the private subnet

Read the Splunk access log:

```bash
az vm run-command invoke --resource-group "<lab-resource-group>" --name "<splunk-vm-name>" --command-id RunShellScript --scripts "docker exec -u 0 splunk sh -c \"grep '/services/mcp' /opt/splunk/var/log/splunk/splunkd_access.log | tail -n 30\"" --query "value[0].message" --output tsv
```

Find entries with:

- `POST /services/mcp`
- HTTP `200` or `202`
- User agent `python-httpx`
- A source IP inside the delegated SRE Agent subnet

The SRE Agent **Network audit** panel might not display this connector flow. It is a filtered ADC sandbox audit rather than a complete VNet flow log. Splunk's source IP evidence or Azure Virtual Network Flow Logs provide the definitive route confirmation.

## 12. Record results

For each test path, record:

| Check | Result |
|---|---|
| Static validation | Pass/fail |
| Deployment completed | Pass/fail and duration |
| VM has no public IP | Pass/fail |
| Peerings connected | Pass/fail |
| Private DNS resolution | Resolved IP |
| Splunk MCP package installed | Version |
| Connector status | Connected/failed |
| Number of tools discovered | Count |
| `splunk_get_info` | Pass/fail |
| `splunk_get_indexes` | Pass/fail |
| Source IP in Splunk log | Address |
| Cleanup completed | Pass/fail |

Capture error text and the failing step number for any failure. Do not include passwords or tokens in the results.

## 13. Cleanup

Before deleting infrastructure:

1. Remove the test connector from SRE Agent.
2. In **Settings > Workspace configuration > Networking**, disconnect the disposable agent from the test VNet or delete the disposable agent.
3. Confirm the agent no longer references the subnet being deleted.

Delete the Bicep test resource group:

```bash
az group delete --name rg-splunk-mcp-bicep-test --yes
```

Destroy the Terraform test:

```bash
terraform -chdir=examples/private-splunk-mcp-cross-region/terraform destroy -var-file=terraform.tfvars
```

Verify the resource groups are gone:

```bash
az group exists --name rg-splunk-mcp-bicep-test
```

```bash
az group exists --name rg-splunk-mcp-tf-test
```

Both commands should return `false`.
