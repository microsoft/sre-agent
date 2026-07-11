# VNet-integrated SRE Agent with a private Key Vault

Terraform example that deploys an Azure SRE Agent injected into a VNet, together
with a Key Vault that has **public access disabled** and is reachable only over
a **private endpoint**. Key Vault traffic - including during connector
setup/validation - stays on the VNet and never traverses the public internet.

Use this when you need the agent to read secrets or use keys (for example a
GitHub App private key) from a locked-down Key Vault.

## How the private path works

The Key Vault FQDN must resolve to the **private endpoint IP** from inside the
agent's VNet. That requires all four of these to line up - miss any one and the
agent falls back to the vault's **public** IP, which a locked-down vault
refuses:

1. The agent is **VNet-injected** into a subnet delegated to
   `Microsoft.App/environments` (`properties.vnetConfiguration.subnetResourceId`).
2. The Key Vault has a **private endpoint** (`groupId = vault`) in that VNet.
3. A **private DNS zone** `privatelink.vaultcore.azure.net` holds an A record
   for the vault pointing at the private endpoint IP.
4. That private DNS zone is **linked to the agent's VNet**.

## What gets deployed

| Resource | Setting that matters |
|---|---|
| VNet `sreagent-vnet` (`10.30.0.0/24`) | One VNet, two subnets |
| ‣ `agent-subnet` (`10.30.0.0/27`) | Delegated to `Microsoft.App/environments` - agent injected here |
| ‣ `pe-subnet` (`10.30.0.32/27`) | Holds the Key Vault private endpoint |
| Key Vault | `public_network_access_enabled = false`, `default_action = Deny`, `bypass = None`, RBAC |
| Private endpoint `pe-kv` | `subresource = vault`, in `pe-subnet` |
| Private DNS zone `privatelink.vaultcore.azure.net` | A record → PE IP, linked to the VNet |
| SRE Agent (`Microsoft.App/agents`) | `vnetConfiguration.subnetResourceId → agent-subnet` |
| User-assigned identity | `Key Vault Crypto User` on the vault |

This is a **single VNet with no Azure Firewall** - that is all that is required
to reach a private-endpoint Key Vault. (A firewall / hub-and-spoke topology is a
separate concern for controlling *outbound internet* egress and is not needed
for the private Key Vault path.)

## Deploy

Prerequisites: `terraform` (or `tofu`) and `az login` into the target
subscription.

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set subscription_id and a globally-unique key_vault_name

terraform init
terraform apply
```

## Validate the path is private

From a shell **inside the agent sandbox** (or any VM on the VNet), resolve the
vault FQDN:

```bash
nslookup <key_vault_name>.vault.azure.net
```

Expected - a **private** address via the `privatelink` CNAME:

```
<kv>.vault.azure.net  canonical name = <kv>.privatelink.vaultcore.azure.net
Address: 10.30.0.36        <-- private endpoint IP (10.x). Correct.
```

- **`10.x` address** → private endpoint path. ✅
- **Public IP** (`20.x`, `40.x`, `13.x`, …) → the FQDN is not using the private
  DNS zone, and a locked-down vault will block it. Re-check items 1–4 above.

## Verify the deployed configuration

```bash
SUB=<sub>; RG=<rg>; KV=<vault>; AGENT=<agent>

# 1. Agent is VNet-injected - subnetResourceId must be set
az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.App/agents/$AGENT?api-version=2026-01-01" \
  --query "properties.vnetConfiguration"

# 2. Key Vault public access is disabled
az keyvault show -g $RG -n $KV \
  --query "{pub:properties.publicNetworkAccess, acls:properties.networkAcls}"

# 3. Private endpoint exists, approved, groupId = vault
az network private-endpoint list -g $RG \
  --query "[].{name:name, status:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status, group:privateLinkServiceConnections[0].groupIds}"

# 4. Private DNS zone is linked to the agent's VNet (most common miss)
az network private-dns link vnet list -g $RG -z privatelink.vaultcore.azure.net \
  --query "[].{name:name, vnet:virtualNetwork.id}"

# 5. A record points at the private endpoint IP
az network private-dns record-set a list -g $RG -z privatelink.vaultcore.azure.net \
  --query "[].{name:name, ips:aRecords[].ipv4Address}"
```

## Notes

- **Region:** VNet injection is regional - the agent subnet must be in the same
  region as the agent.
- **Storing a GitHub App key:** import the `.pem` as a Key Vault **Key** (not a
  secret) so it stays non-exportable; the agent identity (granted
  `Key Vault Crypto User` here) uses the vault's sign operation. The deployer is
  granted `Key Vault Crypto Officer` to perform the import.
