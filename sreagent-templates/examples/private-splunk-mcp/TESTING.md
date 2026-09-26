# Testing the private Splunk MCP template

## Static validation

From `sreagent-templates`:

```bash
bash tests/test-dry-run-private-splunk.sh
```

The consolidated test compiles Bicep, formats/initializes/validates Terraform, parses scripts, exercises both topology samples, and verifies negative validation cases without deploying resources.

## Live validation matrix

Use a unique resource group, name prefix, CIDR range, and connector name for every row:

| Topology | Backend | Required network evidence |
|---|---|---|
| Same region | Bicep | One VNet, no peering, one DNS link |
| Cross region | Bicep | Two VNets, two connected peerings, two DNS links |
| Same region | Terraform | One VNet, no peering, one DNS link |
| Cross region | Terraform | Two VNets, two connected peerings, two DNS links |

For every row:

1. Copy the matching sample, replace the SSH key, and deploy.
2. Confirm the VM has no public IP, the agent subnet is delegated to `Microsoft.App/environments`, and the NSG only permits the agent subnet on ports 8080/8089 before the deny rules.
3. Before the first row, capture the original writable agent state. Stop if that state references infrastructure that no longer exists.
4. Patch to the row's `agentSubnetId`; use the explicit reassignment switch only after capture.
5. Configure Splunk and mint a short-lived encrypted token.
6. Create a uniquely named connector. Never modify an existing connector.
7. Confirm tool discovery, then invoke `splunk_get_info` and `splunk_get_indexes`.
8. Confirm Splunk access logs show the connector request from the delegated subnet.
9. Delete the unique connector, restore and compare captured fields, confirm the old test subnet is no longer referenced, then allow the delegated subnet's service-association link to detach before destroying that row. If Azure returns `InUseSubnetCannotBeDeleted` for `serviceAssociationLinks/legionservicelink`, wait a few minutes, reconfirm the captured agent state, and retry.

After all rows, repeat restore/compare; confirm original connectors are untouched, test connectors and token-bearing Run Commands are absent, and all test resource groups are deleted.

## Commands

Bicep:

```bash
cp examples/private-splunk-mcp/bicep/same-region.parameters.json.example examples/private-splunk-mcp/bicep/main.parameters.json
cd examples/private-splunk-mcp && ./scripts/deploy.sh bicep --resource-group rg-splunk-same-bicep-test --parameters bicep/main.parameters.json
```

Terraform:

```bash
cp examples/private-splunk-mcp/terraform/cross-region.tfvars.example examples/private-splunk-mcp/terraform/terraform.tfvars
cd examples/private-splunk-mcp && ./scripts/deploy.sh terraform --tfvars terraform/terraform.tfvars
```

Inspect topology:

```bash
az network vnet list --resource-group "<rg>" --query "[].id"
az network vnet peering list --resource-group "<rg>" --vnet-name "<vnet>" --query "[].{name:name,state:peeringState}"
az network private-dns link vnet list --resource-group "<rg>" --zone-name lab.internal --query "[].virtualNetwork.id"
```

Configure and mint:

```bash
./scripts/configure-splunk.sh --resource-group "<rg>" --vm-name "<vm>" --package "<package>" --enable-lab-http
./scripts/mint-mcp-token.sh --resource-group "<rg>" --vm-name "<vm>" --scheme http --days 1
```

Pass `--username` only for an account that already exists in Splunk. The setup creates only `admin`; create a restricted user before using a least-privilege username.

Cleanup Bicep:

```bash
az group delete --name "<rg>" --yes
```

Cleanup Terraform:

```bash
terraform -chdir=examples/private-splunk-mcp/terraform destroy -var-file=terraform.tfvars
```

Do not destroy a resource group until restore verification proves the agent no longer references its subnet.
