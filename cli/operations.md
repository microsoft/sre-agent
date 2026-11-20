# Operations guide

Task-oriented workflows for day-to-day use of `az sre`. For the full
command syntax reference, see the [command reference](command-reference.md).

## Agent lifecycle

```bash
az sre agent create --name myagent -g myrg -l eastus2 \
  --default-model "{provider:anthropic,name:automatic}" \
  --mi-system-assigned

az sre agent show -g myrg -n myagent
az sre agent list -g myrg
az sre agent start -g myrg --agent-name myagent
az sre agent stop -g myrg --agent-name myagent
az sre agent delete -g myrg -n myagent -y
```

`start`/`stop` and `connector list-secret` only accept `--agent-name` (no
`-n` shorthand) — this is existing, confirmed-correct behavior, not a bug.

`agent start` waits until the agent's own API answers, which took one to two
minutes in testing. Until then that API answers 404 or 502, so commands that
use it reported items as not found; they also retry a 502, 503 or 504 a few
times, with a warning each time. A delete whose retry finds the item gone
counts as done, since the first try can have gone through. `--no-wait` skips
the wait.

At least one managed identity is required at create time:

```bash
az sre identity assign -g myrg --agent-name myagent --system-assigned
az sre identity show -g myrg --agent-name myagent
az sre identity remove -g myrg --agent-name myagent --system-assigned
```

`identity remove` refuses, before sending anything, a removal that would leave
the agent with no identity. The service rejects that request
(`ManagedIdentityRequired`), but it still deletes the system-assigned
identity's service principal, and the agent goes on reporting a principal that
no longer exists. If that already happened, `identity assign --system-assigned`
makes a new principal; grant it the roles the old one had.

`identity assign` and `identity remove` send a PATCH that carries only the
`identity` block, so the rest of the agent (App Insights link, incident
platform and its key, unit limit, feature flags, networking) is left as it
is. A removed user-assigned identity is sent as `null`; when none remain, the
`type` alone drops them, as `az vm identity remove` does. The identity block is
computed by the extension, not by the generated merge: in azure-cli-core 2.92
that merge removes every user-assigned identity when `identity remove
--user-assigned` names just one. Both commands need `--system-assigned`,
`--user-assigned` or both, and `identity remove` fails before sending anything
if a named identity isn't on the agent. The PATCH was verified offline against
the ARM PATCH rules, not yet against the live service.

`agent wait`, `identity wait` and `connector wait` fail with
"Wait operation timed-out after N seconds" when `--timeout` passes. Earlier
they printed `{}` and exited 0, because azure-cli-core returns the timeout
error instead of raising it.

**Default when neither `--mi-system-assigned` nor `--mi-user-assigned` is
passed to `agent create`**: matches the Azure Portal's own default by
auto-creating a new `Microsoft.ManagedIdentity/userAssignedIdentities`
resource and enabling both system-assigned and user-assigned identities on
the agent (`identity.type = "SystemAssigned, UserAssigned"`). This is
confirmed against the portal's own ARM template
(`createUserIdentity ?? true`) and is now documented directly on both
`--mi-system-assigned`/`--mi-user-assigned` in `--help`, not just a runtime
warning — found during a help-only live walkthrough of the CLI where this
side effect was discoverable only after running the command.

`agent create` fails with "already exists" if the agent name is taken, before
it creates an identity or sends anything else. The create is a PUT, which
replaces the agent: it would attach a new identity in place of the old one
and clear settings the PUT leaves out, such as the App Insights link and the
unit limit. Use `agent update` to change an existing agent. If the existing
agent is Failed or Canceled, the error also offers deleting it first, since
an agent left by a create whose identity was rolled back can't be repaired
with `agent update`. If the agent create fails, the identity made for it is
deleted only when the service rejected the request or reported the operation
Failed or Canceled. After any other failure (a status poll error, or a 404
when reading the agent right after success) the agent may exist and use the
identity, so the command keeps it and says whether the agent exists. If
`--experimental-settings` or `--monthly-unit-limit` can't be applied after the
agent is created, including when that update fails after the service accepted
it, the error says the agent was created and to retry with `agent update`.

## RBAC

```bash
az sre access grant -g myrg --agent-name myagent \
  --assignee someone@example.com --role user
```

`--role` accepts `admin`/`user`/`author`/`reader` — a thin wrapper over
`az role assignment create` that builds the agent's full resource-ID scope,
not a new ARM operation. See the `*_ROLES` constant in `custom.py` for the
exact mapping, confirmed against real `az role definition list` output.
Pass `--assignee-me` instead of `--assignee` to grant yourself access without
looking up your own object ID first (also available as
`az sre agent create --grant-access-to-me <role>` at agent-creation time).
`--assignee-me` reads your object ID (`oid`) from an Azure Resource Manager
access token and your principal type (`User` or `ServicePrincipal`) from
`az account show`, both for the command's `--subscription`, so it picks the
right tenant when your login spans several. It then calls
`az role assignment create --assignee-object-id ... --assignee-principal-type ...`
after checking with `az role assignment list --fill-principal-name false`
whether the assignment already exists (Azure CLI's own "already exists"
handling looks up names in Microsoft Graph).
Use `az sre access list -g myrg --agent-name myagent` to see who has access
to the agent: every role assignment on the agent itself, plus SRE Agent roles
(Administrator, Standard User, Author, Reader) inherited from its resource
group, subscription, or management groups (a wrapper over
`az role assignment list --scope <agent-id> --include-inherited --fill-principal-name false`).
Inherited non-SRE roles such as Owner or Contributor are left out, because the
agent's data plane only accepts the SRE Agent roles. Each item has
`"inherited": true|false`. Principals with Owner or User Access
Administrator on a parent scope can still grant themselves an SRE Agent
role, so for a full access audit also run
`az role assignment list --scope <agent-id> --include-inherited`.
It shows object IDs by default; add `--show-names` to fill in display names
from Microsoft Graph. `-o table` shows a curated
`Principal`/`Type`/`Role`/`GrantedAt`/`GrantedOn` view (not every raw field),
with the object ID in `Principal` when there's no name and `GrantedAt` showing
`agent` or the parent scope the role came from — see the
same note under `sre managed-resource list` below for why.

Only two paths need Microsoft Graph: `access grant/revoke --assignee <email,
UPN or ID>` (Azure CLI resolves the value through Graph) and
`access list --show-names`. Everything else, including `--assignee-me`,
`--grant-access-to-me` and `managed-resource grant/revoke/list`, uses only
Azure Resource Manager. **macOS note:** Conditional Access token protection
in some organizations (for example Microsoft's) rejects Microsoft Graph
tokens from Azure CLI on macOS (`AADSTS530084`), because Azure CLI doesn't
use the sign-in broker there by default (`core.enable_broker_on_mac` is
false). Azure CLI then falls back to an interactive browser sign-in, which
can wait indefinitely in a non-interactive shell. On such machines, use
`--assignee-me` and skip `--show-names`; to grant someone else, call
`az role assignment create --assignee-object-id <id> --assignee-principal-type <type> --scope <agent id>`
directly.

**`--grant-access-to-me` cannot be combined with `--no-wait`** on
`agent create`: the grant runs in the AAZ command's `post_operations()` hook,
which the generated no-wait code path (`build_lro_poller`) never reaches —
advancing the `pre_operations -> yield PUT -> post_operations` generator
only one step before returning. This combination is rejected up front with a
clear `CLIError` instead of silently never granting access.

The mirror image is `az sre managed-resource grant/revoke/list` — instead of
granting a person access *to* the agent, it grants the agent's own managed
identity Reader + Monitoring Contributor *on* an external subscription,
resource group, or management group. This is the role-assignment half of the
portal's Build + setup > Context > Managed resources page: the portal also
adds the scope to `properties.knowledgeGraphConfiguration.managedResources`,
and this command doesn't, so the scope isn't listed on that page (see the
[portal and CLI handoff guide](portal-cli-handoff.md#what-the-cli-does-differently)):

```bash
az sre managed-resource grant -g myrg --agent-name myagent \
  --target-subscription <sub-id> --target-rg monitored-rg
az sre managed-resource list -g myrg --agent-name myagent
az sre managed-resource revoke -g myrg --agent-name myagent \
  --target-subscription <sub-id> --target-rg monitored-rg
```

All three commands target the identity the agent is configured to use for
managed resources, matching the portal's Managed resources page:
`properties.knowledgeGraphConfiguration.identity`, or
`properties.actionConfiguration.identity` when that is empty. `system` (or
`SystemAssigned`) means the system-assigned managed identity (SAMI); a full
ARM resource ID means that user-assigned managed identity (UAMI). If neither
is set, they use the SAMI, or the agent's only UAMI; with several UAMIs and
no configuration, they ask for `--identity`. To target another attached
identity, pass `--identity system` or a UAMI's full ARM resource ID on
**grant, list, and revoke**:

```bash
UAMI_ID="/subscriptions/<sub-id>/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runtime"

az sre identity show -g myrg --agent-name myagent
az sre managed-resource grant -g myrg --agent-name myagent \
  --identity "$UAMI_ID" --target-subscription <sub-id> --target-rg monitored-rg
az sre managed-resource list -g myrg --agent-name myagent --identity "$UAMI_ID"
az sre managed-resource revoke -g myrg --agent-name myagent \
  --identity "$UAMI_ID" --target-subscription <sub-id> --target-rg monitored-rg
```

UAMI resource IDs (passed or configured) are matched case-insensitively
against `identity show`'s `userAssignedIdentities`; names, client IDs,
principal IDs, unassigned UAMIs, and identities without principal metadata
are rejected. A configured value that isn't a managed identity (for example
an agent identity name) is rejected with a hint to pass `--identity`.
Selection uses the attached identity's `principalId`, with no additional
directory lookup. The selected identity, its principal ID, and where the
choice came from are logged on stderr (unless `--only-show-errors`
suppresses warnings), including when a list is empty. These commands do not
attach identities or change the agent's configuration.

**Upgrading from earlier versions:** before this change, these commands
always defaulted to the SAMI. If an agent is configured to use a UAMI, roles
granted earlier with the old default stay on the SAMI, and a plain `revoke`
now targets the UAMI instead. Check with
`az sre managed-resource list ... --identity system` and remove them with
`az sre managed-resource revoke ... --identity system`.

Grant and revoke operate on Reader + Monitoring Contributor as a pair by
default, matching the portal. Pass `--roles` to use a different set, e.g. the
zava-aks-postgres lab also grants Contributor and Monitoring Reader:

```bash
az sre managed-resource grant -g myrg --agent-name myagent \
  --target-subscription <sub-id> --target-rg monitored-rg \
  --roles Reader "Monitoring Reader" "Monitoring Contributor" Contributor
```

`--roles` replaces the default pair rather than adding to it, so list every
role you want. Revoke is limited to the chosen identity and exact requested scope, preserving
other principals, other roles, and assignments on parent or child scopes.
List retains `az role assignment list --all`'s current-subscription scope and
returns every role, not just the managed pair, for the chosen identity.

`access list` and `managed-resource list` both return a raw
`az role assignment list` object (a dozen-plus flat top-level fields —
`id`/`principalId`/`principalName`/`principalType`/`roleDefinitionId`/
`roleDefinitionName`/`scope`/`createdBy`/`createdOn`/`updatedBy`/`updatedOn`),
which az's default `-o table` auto-generator renders as one column per
field — confirmed live to wrap into an unreadable wall of text at a normal
terminal width. Both commands register a custom `table_transformer`
(`_transformers.py`) that curates the columns actually useful for each: a
`Principal`/`Type`/`Role`/`GrantedAt`/`GrantedOn` view for `access list`
(`GrantedAt` is `agent` or the parent scope an SRE Agent role is inherited
from), and a
`Scope`/`Role`/`PrincipalType`/`GrantedOn` view for `managed-resource list`
(the principal is the selected agent identity, reported separately on stderr).
`-o json`/`-o jsonc`/`-o yaml`/etc. are unaffected and
still return every field.

## Data connectors

Create connectors with `az sre connector create`. See
[connector types](connector-types.md) for the `--data-connector-type` values and
the [command reference](command-reference.md) for every option.

## Agent extensions

Tools, skills, hooks, instructions, sub-agents, automations, plugins and response
plans each have their own command group. `--value` must be a JSON object at the
root; a bare JSON array is rejected.

### Credentials in tool and plugin values

A plugin marketplace's `credentials.pat`, an HttpClientTool's auth headers
(such as `Authorization` or an API key) and a plugin install's
`source.credentials.pat` are secrets. `show`, `list` and `create` for `tool`,
`plugin marketplace` and `plugin install` print them as `******` and keep the
service's replies out of `--debug` and the Azure CLI log file. Don't paste
that output back as `--value`: `create` refuses a value that still has
`******` in a credential field, so the mask can't replace the real secret.

### Non-Microsoft tenants

The service currently rejects agent extension calls through ARM from
non-Microsoft tenants with "This feature is restricted to internal tenants
only". When that happens, these commands retry on the agent's own API, the
same one the Azure SRE portal uses:

`tool`, `skill`, `hook`, `instructions`, `subagent`, `automation scheduled-task`,
`automation http-trigger`, `plugin marketplace`, `plugin install`,
`agent settings`, `response-plan`, `repo connect` and its GitHub / Azure DevOps
credentials. On that API, sub-agents are `agents`
(`/api/v2/extendedAgent/agents`).

Changing anything through the agent's API needs the **SRE Agent Author** or
**SRE Agent Administrator** role on the agent. `agent settings` can be shown and
updated but not listed or deleted this way. A request the agent's API has no
route for fails with a message that ARM refused the tenant and points to the
Azure SRE Agent portal.

The CLI asks the agent once (`GET /api/v1/feature/status`) whether it is a
Microsoft first-party agent, and remembers the answer for 24 hours in
`sre_agent_features.json` in the Azure CLI config folder. For other tenants it
goes straight to the agent's API, so there is no failed first call. If the agent
can't be asked, it tries ARM first and falls back as described above. Set
`AZSRE_EXTENSION_ROUTE=direct` or `arm` to force a route. Creating scheduled
tasks or HTTP triggers on an agent that reports the feature as off fails with a
clear message.

Some features are Microsoft-internal, as in the portal. On an agent that
reports it isn't first-party, `connector create` rejects the `Dgrep`,
`GenevaMetrics` and `S360` types. IcM (the `Icm` connector
type, `response-plan --platform Icm` and `agent create/update` with
`type=Icm`) is blocked the same way, because in
the public cloud IcM is offered only to first-party tenants. Use PagerDuty,
ServiceNow or Azure Monitor instead.

`--help` can't ask the agent, so it goes by the tenant you're signed in to
(read from the local Azure CLI profile, no network call). For other tenants it
doesn't mention these internal options, as the portal hides them. If the tenant
can't be read, help lists them. Typing one anyway still gets the error above.

## Networking

See the [networking guide](networking.md) for VNet injection and sandbox
egress configuration via `network update`.

## Windows PowerShell: JSON quoting

Bash-style `--value '{"key": "value"}'` quoting (single-quoted string
containing literal, unescaped double quotes) does **not** survive
`powershell.exe`/`pwsh` invoking `az` (which is `az.cmd`, a batch-wrapped
executable). The embedded `"` characters get re-tokenized on the way to the
native command line, producing either:

- `ERROR: unrecognized arguments: ...` (argument got split on whitespace
  inside the JSON), or
- `--value must be a JSON document... Expecting property name enclosed in
  double quotes` (the JSON arrived with its quotes stripped).

This reproduces identically regardless of spaces around `:` or any
particular character inside the string — it is PowerShell's general handling
of embedded `"` in a single-quoted argument being passed to a `.cmd`-wrapped
executable, not specific to any one flag or payload. It affects every Azure
CLI command that takes inline JSON, not just `az sre`.

**Fix: escape the inner double quotes with a backslash, keep the outer
single quotes:**

```powershell
# Fails on Windows PowerShell:
az sre instructions create -g myrg --agent-name myagent --name default `
  --value '{"prompt": "Escalate before restarting."}'

# Works on Windows PowerShell:
az sre instructions create -g myrg --agent-name myagent --name default `
  --value '{\"prompt\":\"Escalate before restarting.\"}'
```

Bash/zsh users are unaffected and can keep using the unescaped form shown
throughout this guide and the quickstart.

## Usage and endpoint info

```bash
az sre endpoint show -g myrg -n myagent
az sre usage list -g myrg -n myagent
az sre agent list-models -l eastus2
```

`usage list` returns the usage items as a list and follows `nextLink`, so
`-o table` shows them. Its `usages` and `dailyusages` routes aren't in the
2026-01-01 API specification, and their item shape hasn't been checked live.

`endpoint show` saves the endpoint to `~/.azure/sreAgentConnections.json` for
data-plane tools, keyed `<subscription-id>/<resource-group>/<agent-name>`, so
same-named agents in different subscriptions get separate entries. Entries
that older versions saved as `<resource-group>/<agent-name>` are kept as they
are. The new file replaces the old one in a single step, so a failed write
leaves the previous file intact, and a file saved with a UTF-8 byte order mark
is read normally. The file stays in `~/.azure` even when `AZURE_CONFIG_DIR`
points somewhere else.
