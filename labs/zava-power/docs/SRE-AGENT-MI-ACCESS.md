# SRE Agent — Managed Identity Access Model

The PowerGrid SRE Agent uses an **adaptive RBAC tier model** chosen at deploy time. Three tiers exist; the deploy probe (`scripts/check-environment.ps1`) picks the most restrictive one available, prompting on fallback.

## Read paths (granted in all 3 tiers)

| Built-in role | Why |
|---|---|
| `Reader` | Resource enumeration across the RG (List Container Apps, list VMs, etc.) |
| `Monitoring Reader` | Read Azure Monitor metrics, alert rules, alert history |
| `Log Analytics Reader` | Run KQL queries against the workspace (App Insights traces, container logs, AzMon log alerts) |

These three roles let the agent **detect and diagnose** without any write actions. Sufficient for "tell me what's wrong"; not sufficient for "fix it."

## Operator role (write paths) — varies by tier

### Tier 1: `PowerGrid SRE Agent Operator` (custom, least-priv) ✨ default

Definition: [`infra/roles/powergrid-sre-agent-operator.json`](../infra/roles/powergrid-sre-agent-operator.json)

| Action | Used by skill / scenario |
|---|---|
| `Microsoft.App/containerApps/write` | Update container image to roll back a bad deploy |
| `Microsoft.App/containerApps/listSecrets/action` | Read secrets when re-rendering CA template |
| `Microsoft.App/containerApps/revisions/activate/action` | Activate a previous good revision (rollback path) |
| `Microsoft.App/containerApps/revisions/deactivate/action` | Deactivate a bad revision |
| `Microsoft.App/containerApps/revisions/restart/action` | Restart a stuck revision |
| `Microsoft.Compute/virtualMachines/runCommand/action` | Disk-pressure remediation: clean up logs/temp on VM |
| `Microsoft.Compute/virtualMachines/runCommands/write` | Persistent run-commands |
| `Microsoft.Compute/virtualMachines/runCommands/delete` | Cleanup |
| `Microsoft.Compute/virtualMachines/restart/action` | Hard-restart VM as last resort |
| `Microsoft.HybridCompute/machines/runCommands/write` | Same, for Arc-enabled servers |
| `Microsoft.HybridCompute/machines/runCommands/delete` | Cleanup |

`AssignableScopes` is the lab's RG only. Blast radius bounded.

**Created idempotently** by the deploy probe via `az role definition create -f <substituted-template>`. If a role with the same name already exists in the sub, the probe re-uses it.

### Tier 2: `Contributor` (built-in)

Built-in role `b24988ac-6180-42a0-ab88-20f7382dd24c`. Scoped to the lab's RG.

**When this tier kicks in:** the T1 probe failed for one of:
- Tenant custom-role limit exceeded (5000 roles per tenant)
- Caller lacks `Microsoft.Authorization/roleDefinitions/write` (i.e., not Owner / User Access Administrator)

**Capability impact:** none — the agent has the same actions as T1 plus much more. The trade-off is **broader blast radius**: Contributor permits writes on any resource type in the RG. Acceptable for a demo lab, not recommended for production.

### Tier 3: read-only

No operator role is granted. The agent retains Reader/MonReader/LAReader and can investigate.

**When this tier kicks in:** T1 failed and the user chose T3 at the prompt (or `azd up --no-prompt` was used).

**How remediation still happens:** `actionConfiguration.mode = Review`, so every action the agent decides to take is queued for human approval. In T3 the human approver completes the action with their own perms.

## Why `actionConfiguration.mode = Review` in all tiers

Even in T1 and T2 — where the agent technically *could* perform the action — every remediation goes through the approval flow. This:

1. Keeps a human in the loop for any production-impacting change
2. Means T3 isn't a UX cliff — the same approval prompt fires, the only difference is who clicks "approve" actually executes the action
3. Lets you audit decisions in the agent thread before they're applied

## Verification snippet

After `azd up`, check the actual assignments:

```bash
az role assignment list \
  --resource-group rg-powergrid \
  --assignee $(az identity show -n id-powergrid-sre -g rg-powergrid --query principalId -o tsv) \
  --query "[].{Role:roleDefinitionName, Scope:scope}" -o table
```

Expected output (T1):
```
Role                                  Scope
------------------------------------  --------------------------------
Reader                                /subscriptions/.../rg-powergrid
Monitoring Reader                     /subscriptions/.../rg-powergrid
Log Analytics Reader                  /subscriptions/.../rg-powergrid
PowerGrid SRE Agent Operator          /subscriptions/.../rg-powergrid
```

T2 substitutes `Contributor` for the last row. T3 omits the last row.

## Upgrading tiers

```bash
# Force a specific tier on the next deploy
azd env set RBAC_TIER custom        # or contributor / readonly
azd provision

# Or unset to re-probe fresh
azd env unset RBAC_TIER
azd provision
```

## Why custom over Contributor by default?

PowerGrid is a multi-scenario lab demonstrating autonomous SRE remediation. The custom role exists to show the **production-style least-priv pattern** customers should use — Contributor is the lazy answer; the custom role is the "show what good looks like" answer. The fallback exists so the lab is still demoable when the custom role can't be created (corporate tenants frequently hit the 5000-role limit).
