# Networking guide

`network update` configures VNet injection (outbound) and sandbox
egress for an SRE Agent. It is **hand-written, not generated** — there is
no public Swagger for the api-version that actually supports these fields
in production (`2026-11-01-preview`; see `NETWORK_API_VERSION` in
`custom.py`). It sends an ARM PATCH carrying only the networking objects the
caller supplied (`vnetConfiguration` or `sandboxConfiguration`), so the rest
of the agent, including an Application Insights link whose connection string
the service never returns, is left untouched.

## Inspect current networking configuration

```bash
az sre network show -g myrg --agent-name myagent
```

This returns the VNet injection and sandbox egress settings. `az sre agent show` omits them: the service returns them at `2026-01-01` too, but the generated `agent show` schema doesn't model these fields, so they're dropped from its output. Use `network show` to read them back.

A new agent starts with `Limited` egress and a service-managed default allow list: 45 hosts on 2026-11-10 (Azure management, Microsoft Graph, Log Analytics, Kusto, GitHub, Azure DevOps and similar), the `pypi`, `npmjs`, `nuget-org` and `ubuntu` registries, the `Github`, `AzureDevOps` and `GithubEnterprise` code repositories, and `allowHttpMcpServerNetworkAccess: true`. Its `vnetConfiguration.subnetResourceId` is `null`.

## Configure sandbox egress

```bash
az sre network update -g myrg --agent-name myagent \
  --sandbox-configuration "{egress:{mode:Unrestricted}}"

az sre network update -g myrg --agent-name myagent \
  --sandbox-configuration "{egress:{mode:Limited,allowed-hosts:[example.com]}}"
```

The service merges `--sandbox-configuration` into the existing settings:
fields you leave out keep their current values, and a list you pass replaces
that list. For `allowed-hosts`, `network update` reads the agent's current
list first and sends it back with your hosts added. So the `Limited` command
above adds `example.com` and keeps the service's default hosts, registries,
code repositories and `allowHttpMcpServerNetworkAccess`. Other lists, such as
`allowed-registries`, replace the stored list.

To remove allowed hosts, pass the complete list with `--replace-allowed-hosts`.
A warning names the hosts it removes, which can include the service's
defaults. Start from the current settings:

```bash
az sre network show -g myrg --agent-name myagent --query sandboxConfiguration > sandbox.json
# Edit egress.allowedHosts in sandbox.json. Fields left as null are ignored.
# Don't commit the file: it holds any proxy URLs set on the agent.
az sre network update -g myrg --agent-name myagent --replace-allowed-hosts \
  --sandbox-configuration @sandbox.json
```

Because fields set to `null` are ignored, `network update` can't clear a
setting such as an HTTP proxy or the VNet subnet. A `--vnet-configuration` or
`--sandbox-configuration` value that sets nothing once nulls are dropped (for
example `"{egress:{http-proxy:null}}"` or `"{}"`) fails before anything is sent,
instead of sending an empty PATCH and exiting 0. An empty list does count: it
clears the stored list (for `allowed-hosts`, only with `--replace-allowed-hosts`).

Proxy URLs can carry credentials, so `network update` keeps its request and
response bodies out of `--debug` output and `az.log`. A value typed on the
command line still shows up in the `--debug` argument echo and shell history,
so the command warns when a proxy URL with credentials was typed inline; pass
`--sandbox-configuration @file` instead. `network show` prints proxy URLs as
stored.

## Configure VNet injection

Use a dedicated subnet prepared for this agent, delegated to
`Microsoft.App/environments`. The example assumes an existing VNet and
subnet in the agent's region; replace the network resource names with your
approved resources. Do not change the delegation of a shared or in-use
subnet.

```bash
NETWORK_RG="network-rg"
VNET="agent-vnet"
SUBNET="agent-subnet"

az network vnet subnet update -g "$NETWORK_RG" --vnet-name "$VNET" \
  --name "$SUBNET" --delegations Microsoft.App/environments

SUBNET_ID=$(az network vnet subnet show -g "$NETWORK_RG" --vnet-name "$VNET" \
  --name "$SUBNET" --query id -o tsv)

az sre network update -g myrg --agent-name myagent \
  --vnet-configuration "{subnet-resource-id:$SUBNET_ID}" \
  --sandbox-configuration "{egress:{mode:AzureVNet}}"
```

The VNet configuration and `AzureVNet` sandbox egress mode must be applied
together; the subnet ID alone is not sufficient. Subnet delegation is a
separate prerequisite and is not performed by `az sre network update`.

## Important sequencing note

`network update` is itself a long-running operation — the agent enters
`provisioningState: InProgress` while it applies. Any other mutating
command issued against the same agent while this is in flight will be
rejected with a clean `OperationConflict` error
(`"Agent '<name>' is currently being provisioned and cannot be created or
updated."`). Wait for completion before issuing the next command:

```bash
az sre agent wait -g myrg -n myagent --updated --timeout 300
```

## Reading networking settings

Use `az sre network show` to read networking settings back. `az sre agent show`
uses an older API version that doesn't include the networking fields, so they
show as `null` there.

