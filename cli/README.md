# Quickstart: set up your SRE agent

This guide takes you from nothing to a working SRE agent: create it, connect a repository
and a data source, share it, let it monitor your Azure resources, add a custom skill and
route incidents to it.

The examples use bash. If you use PowerShell, see
[JSON quoting on Windows](operations.md#windows-powershell-json-quoting).

## Install

You need Azure CLI 2.75.0 or later. Then install the `sre` extension.

macOS, Linux, WSL or Cloud Shell (bash):

```bash
curl -fsSL https://aka.ms/az-sre-cli-install | bash
```

Windows (PowerShell):

```powershell
irm https://aka.ms/az-sre-cli-install-ps | iex
```

This installs `sre` version 1.0.0b2 (preview). The installer checks the wheel's
SHA-256 before installing it. Run the same command again
to upgrade, and check the install with `az sre --help`.

## Prerequisites

These requirements match the portal's; see
[Create and set up Azure SRE Agent](https://learn.microsoft.com/azure/sre-agent/create-and-set-up#prerequisites).
To list your Azure roles, run
`az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" --all --include-groups -o table`.
It covers roles you get through a group, but only in the current subscription; for a
cluster in another subscription, add `--subscription <cluster-subscription-id>`.

### Required

| You need                                                                                                  | How to check                                                                           |
| --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.75.0 or later                      | `az version`                                                                           |
| The `sre` extension                                                                                       | `az extension show --name sre`. To install it, see [Install](#install).                |
| Owner, or Contributor plus User Access Administrator, on the subscription or resource group for the agent | Role list above                                                                        |

### Optional

Only needed for the step listed. Without them, that step fails with a permission error,
and the error doesn't always say which permission is missing.

| You need                                                                                           | For                                                                         | How to check                           |
| -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | -------------------------------------- |
| A GitHub account that can read the repository                                                      | [Connecting a repository](#connect-a-repository)                            | Open the repository in a browser       |
| Contributor or Owner on the Azure Data Explorer cluster, to grant access with the Azure CLI        | [Connecting a data source](#connect-a-data-source)                          | Role list above                        |
| Admin on the Azure Data Explorer database, to grant access with a KQL command instead              | [Connecting a data source](#connect-a-data-source)                          | `.show database <database> principals` |
| Owner or User Access Administrator on each subscription or resource group the agent should monitor | [Letting it monitor resources](#let-the-agent-monitor-your-azure-resources) | Role list above                        |

## Sign in and set variables

```bash
az login

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
LOCATION="eastus2"
TEST_ID="$(date +%s)"
RG="rg-sre-${TEST_ID}"
AGENT="sre-${TEST_ID}"
```

## Create the agent

```bash
az group create \
  --subscription "$SUBSCRIPTION_ID" \
  --name "$RG" \
  --location "$LOCATION"

az sre agent create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --name "$AGENT" \
  --location "$LOCATION" \
  --grant-access-to-me admin
```

`az sre agent create` gives the agent a user-assigned managed identity and turns on a
system-assigned one too. The agent works through these identities, not yours, so every
data source it reads needs its own grant to one of them. Creating a connector doesn't
give the agent access.

```bash
az sre agent show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --name "$AGENT" \
  --output table
```

## Connect a repository

For GitHub, the command shows a one-time code and opens GitHub's sign-in page in
your browser; enter the code there. In CI, set `GITHUB_TOKEN` or pass
`--github-token` instead. The agent keeps one GitHub credential for all its
GitHub repositories, so use a token that can read every repository you connect.

```bash
az sre repo connect \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --agent-name "$AGENT" \
  --repo-url "https://github.com/<org>/<repo>"
```

## Connect a data source

1. Create a `Kusto` connector that names the cluster and database. Create one per
   database the agent should query:

   ```bash
   az sre connector create \
     --subscription "$SUBSCRIPTION_ID" \
     --resource-group "$RG" \
     --agent-name "$AGENT" \
     --name production \
     --data-connector-type Kusto \
     --data-source "https://<cluster>.<region>.kusto.windows.net/<database>"
   ```

   - `--name` is a label you choose.
   - `--data-connector-type Kusto` connects Azure Data Explorer through the agent's
     managed identity.
   - `--data-source` is the cluster URL followed by the database name.

   In the portal, under **Connectors**, it shows up as "Azure Data Explorer" with the
   status **Connected** right away. That only means the connector was saved. Queries
   fail with a permission error until you grant access in step 3.

2. Get the principal ID and tenant of the identity the connector queries with. A
   connector created without `--identity` uses the agent's **system-assigned** identity.
   That's the one that worked in a live test; granting the user-assigned identity instead
   creates the grant but queries still fail.

   ```bash
   PRINCIPAL_ID=$(az sre agent show \
     --subscription "$SUBSCRIPTION_ID" \
     --resource-group "$RG" \
     --name "$AGENT" \
     --query identity.principalId \
     --output tsv)

   PRINCIPAL_TENANT_ID=$(az sre agent show \
     --subscription "$SUBSCRIPTION_ID" \
     --resource-group "$RG" \
     --name "$AGENT" \
     --query identity.tenantId \
     --output tsv)
   ```

3. Grant that identity Viewer on the database. This needs the `kusto` extension
   (`az extension add --name kusto`) and Contributor or Owner on the cluster in Azure.
   The cluster can be in a different subscription from the agent, so set it explicitly:

   ```bash
   CLUSTER_SUBSCRIPTION_ID="<cluster-subscription-id>"

   az kusto database-principal-assignment create \
     --subscription "$CLUSTER_SUBSCRIPTION_ID" \
     --cluster-name <cluster> \
     --resource-group <cluster-resource-group> \
     --database-name <database> \
     --principal-assignment-name "$AGENT-viewer" \
     --principal-id "$PRINCIPAL_ID" \
     --principal-type App \
     --role Viewer \
     --tenant-id "$PRINCIPAL_TENANT_ID"
   ```

   Repeat it for each database the agent should query.

   Without Azure access to the cluster, a database Admin can grant it in Azure Data
   Explorer instead. They'll need the identity's app ID, which
   `az ad sp show --id "$PRINCIPAL_ID" --query appId --output tsv` returns:

   ```kusto
   .add database <database> viewers ('aadapp=<app-id>')
   ```

   Either way, `.show database <database> principals` lists the grant.

4. Check that it works by asking the agent in the portal chat:

   > Run `.show tables` on the `<database>` database at
   > `https://<cluster>.<region>.kusto.windows.net` and list what you find.

   A list of table names means the setup is complete. If you get an error like
   `Principal 'aadapp=<app-id>;<tenant-id>' is not authorized to read database`, that
   `<app-id>` is the identity the agent actually used. Run
   `az ad sp show --id <app-id> --query id --output tsv` to get its principal ID and
   grant that one in step 3.

For more about the connector, see
[Connect Kusto](https://learn.microsoft.com/azure/sre-agent/kusto-connector).

## Share the agent

Give yourself, a teammate or a group a built-in role on the agent: `admin`, `author`,
`user` or `reader`.

```bash
az sre access grant \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --agent-name "$AGENT" \
  --role user \
  --assignee "<user-or-group-object-id>"
```

To grant the role to the signed-in user, pass `--assignee-me true` instead of `--assignee`.
List who has access with `az sre access list`.

## Let the agent monitor your Azure resources

An agent can only investigate resources its identity can read. Grant it Reader and
Monitoring Contributor on the resource group to monitor:

```bash
az sre managed-resource grant \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --agent-name "$AGENT" \
  --target-subscription "$SUBSCRIPTION_ID" \
  --target-rg "<resource-group-to-monitor>"
```

To cover a whole subscription, omit `--target-rg`. Check the result with
`az sre managed-resource list` and undo it with `az sre managed-resource revoke`.

These commands use the identity the agent is configured to use for managed
resources (`knowledgeGraphConfiguration.identity`, then
`actionConfiguration.identity`), the same one the portal uses. If neither is
set, they use the system-assigned identity, or the agent's only user-assigned
identity. To target another attached identity, pass `--identity system` or
`--identity "<assigned-UAMI-ARM-ID>"` to **grant, list, and revoke**. Selecting an
identity for RBAC does not change the agent's configuration.
See the [identity selection workflow](operations.md#rbac) for a complete example.

## Add a custom skill

A skill teaches the agent a procedure. Write it as a `SKILL.md` file with a description
and the steps to follow:

```markdown
---
description: Check a service's health before escalating
---

# Service health check

1. Query the last hour of error rates for the service.
2. Compare them with the previous day.
3. Report whether the change is within normal range.
```

Then create the skill from the file:

```bash
az sre skill create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --agent-name "$AGENT" \
  --name service-health-check \
  --file-path ./SKILL.md
```

## Route incidents to the agent

Send high-severity Azure Monitor incidents to a subagent. First connect Azure Monitor as
the agent's incident platform:

```bash
az sre agent update \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --name "$AGENT" \
  --incident-management-configuration '{type:AzMonitor,connection-name:azmonitor}'
```

Then create the subagent that handles the incidents. Save its configuration as
`subagent.json`. `instructions` must be at least 50 characters, and `handoffDescription`
tells the main agent when to hand work over:

```json
{
  "instructions": "You triage Azure Monitor alerts for the web API and summarize the evidence you find.",
  "handoffDescription": "Use for triaging Azure Monitor alerts on the web API."
}
```

```bash
az sre subagent create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --agent-name "$AGENT" \
  --name triage \
  --value @subagent.json
```

Now create the response plan. Start in review mode, so the agent proposes actions and you
approve each one:

```bash
az sre response-plan create \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --agent-name "$AGENT" \
  --name sev1-api \
  --platform AzMonitor \
  --subagent triage \
  --priority Sev0 Sev1 \
  --mode review
```

Pause the plan without deleting it with `az sre response-plan disable`. For PagerDuty or
ServiceNow, and for the steps that still need the portal, see
[Step 4: Set up incident response](portal-cli-handoff.md#step-4-set-up-incident-response).
IcM works only on Microsoft first-party agents; see
[Non-Microsoft tenants](operations.md#non-microsoft-tenants).

## Clean up

> [!CAUTION]
> This permanently deletes the resource group and everything in it, including the agent.
> Confirm the variables before running it. It does not delete the repository or the
> Azure Data Explorer cluster.

Deleting the resource group doesn't remove the database grant from
[Connect a data source](#connect-a-data-source), because it lives on the cluster. Remove it
first:

```bash
az kusto database-principal-assignment delete \
  --subscription "$CLUSTER_SUBSCRIPTION_ID" \
  --cluster-name <cluster> \
  --resource-group <cluster-resource-group> \
  --database-name <database> \
  --principal-assignment-name "$AGENT-viewer" \
  --yes
```

If you granted access with the KQL command instead, run
`.drop database <database> viewers ('aadapp=<app-id>')`.

Then delete the resource group:

```bash
printf 'Deleting subscription=%s resource-group=%s\n' \
  "$SUBSCRIPTION_ID" "$RG"

az group delete \
  --subscription "$SUBSCRIPTION_ID" \
  --name "$RG" \
  --yes \
  --no-wait
```

## Next steps

- [Command reference](command-reference.md): every command, option and example
- [Portal and CLI handoff guide](portal-cli-handoff.md): each Microsoft Learn tutorial step, with
  the command to run or the portal page to use
- [Connector types](connector-types.md): the values for `--data-connector-type`
- [Operations guide](operations.md): connectors, networking, RBAC and incident handling in depth
- Questions or bugs: [open an issue](https://github.com/microsoft/sre-agent/issues)
