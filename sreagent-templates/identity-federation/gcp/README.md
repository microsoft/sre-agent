# SRE Agent GCP connector setup

This package uses Terraform to configure the GCP Workload Identity pool,
OIDC provider, `readSRE` and `writeSRE` custom IAM roles, and separate role assignments required by
the SRE Agent GCP connector.

Provide the user-assigned managed identity's ARM resource ID, not the SRE Agent
resource ID. System-assigned identities and sovereign-cloud issuers are not supported.

## Download the files

Clone this repository and open a terminal in the GCP setup folder:

```powershell
git clone https://github.com/microsoft/sre-agent.git
cd sre-agent\sreagent-templates\identity-federation\gcp
```

On Linux or macOS, use `cd sre-agent/sreagent-templates/identity-federation/gcp`.
Follow the steps below from that folder. Keep the setup scripts, all `.tf`
files, and both role JSON files together.

## Permission catalogs

Review the two custom roles independently:

| Role / file | Access | Assigned for |
| --- | --- | --- |
| [`readSRE`](./readSRE.json) | Resource discovery, metadata, logs, metrics, and Storage object reads | `read-only` and `read-write` |
| [`writeSRE`](./writeSRE.json) | Workload changes and operation-status reads needed by those changes | `read-write` only, separately from `readSRE` |

Both custom roles are created at the selected scope. The supplied managed
identity receives only `readSRE` for `read-only`, or two separate IAM memberships
for `read-write`. The write catalog does not duplicate the read catalog. At
organization scope, Terraform additionally includes
`resourcemanager.projects.list` in `readSRE`; that permission is not applicable
to a project-level custom role.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli),
  [Google Cloud CLI](https://cloud.google.com/sdk/docs/install), and a stable
  [Terraform 1.7 or later](https://developer.hashicorp.com/terraform/install).
- Windows: [PowerShell 7 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell).
- Linux or macOS: Bash and [`jq`](https://jqlang.org/download/); PowerShell is not required.
- **EnableGcpCloudProvider** enabled in SRE Agent **Experimental Settings**.
- An existing user-assigned managed identity available to SRE Agent, with Azure
  read access. Setup does not create or attach the identity.
- A configured GCP project with `serviceusage.googleapis.com` and
  `iam.googleapis.com` enabled before discovery.
- GCP permissions to inspect the project/services, manage workload identity
  pools/providers and custom roles, enable APIs, and read/update project IAM.
  Relevant predefined roles: `roles/iam.workloadIdentityPoolAdmin`,
  `roles/iam.roleAdmin`, `roles/resourcemanager.projectIamAdmin`,
  `roles/serviceusage.serviceUsageAdmin`. Use policy-approved, least-privilege access.

### Verify the installation

```text
az version
gcloud --version
terraform version
```

Linux and macOS customers should also run:

```bash
jq --version
```

## Windows

### 1. Authenticate and configure the project

Open PowerShell 7 in this folder:

```powershell
az login
gcloud auth login
gcloud config set project <PROJECT_ID>
gcloud config get project
```

Setup uses the active `gcloud` account and configured project; an unset or
inaccessible project fails.

### 2. Run setup

Keep `setup.ps1`, all `.tf` files, and both role JSON files together. Replace the example resource ID:

```powershell
.\setup.ps1 `
  -ResourceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/my-group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-identity' `
  -allowed-permissions read-write `
  -skip-approval true
```

| Parameter | Required | Values |
| --- | --- | --- |
| `-ResourceId` | Yes | Full user-assigned managed identity ARM resource ID. |
| `-allowed-permissions` | Yes | `read-only` or `read-write`. |
| `-skip-approval` | No | `true` or `false`; defaults to `false`. |

**`-skip-approval true` applies all changes without confirmation.** Omit it or
set `false` to review the Terraform plan and enter `yes` to apply.

## Linux or macOS

### 1. Authenticate and configure the project

Open Bash in this folder:

```bash
az login
gcloud auth login
gcloud config set project <PROJECT_ID>
gcloud config get project
```

### 2. Run setup

Keep `setup.sh`, all `.tf` files, and both role JSON files together. Replace the example resource ID:

```bash
chmod +x setup.sh
./setup.sh \
  --resource-id='/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/my-group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-identity' \
  --allowed-permissions=read-write \
  --skip-approval=true
```

The Bash parameters match the PowerShell parameters above. Omit
`--skip-approval` or set `--skip-approval=false` to review the plan before applying.

## What the setup script does

- Resolves the tenant and principal/object IDs with `az identity show --ids`;
  resolves the project ID/number from `gcloud`.
- Discovers the existing pool, provider, custom roles, and role assignments for
  the selected identity. Generates Terraform import blocks for these resources
  and enabled APIs; imports the role assignment only if it has no IAM condition.
  Pool/provider imports use the configured project ID to avoid replacement;
  discovery and federated principal names use the project number.
- Extends compatible provider trust and fetches each existing role's
  `includedPermissions`. Each role receives the union of its own existing
  permissions and its own JSON catalog; missing catalog permissions are added,
  and manual additions are retained. Permissions are never copied between roles.
  If an existing role's permissions cannot be read as an array of nonempty
  strings, setup fails before applying changes.
- Ensures IAM, Resource Manager, Service Account Credentials and STS APIs are
  enabled; applies an additive IAM member without replacing other bindings.
- Imports obsolete memberships for the selected identity into temporary
  Terraform resources, then removes their configuration so their deletion
  appears in the same approval plan as the new assignments. Import itself
  does not change remote IAM policy.
- Runs `terraform init` and `apply` in a unique temporary CLI workspace, then
  deletes the workspace and local files without running `terraform destroy`.

## Federation configuration

| Resource | Fixed ID | Display name |
| --- | --- | --- |
| Workload Identity pool | `sre-agent-pool` | `SREAgentPool` |
| OIDC provider | `sre-agent-provider` | `SREAgentProvider` |
| Read custom IAM role | `readSRE` | `readSRE` |
| Write custom IAM role | `writeSRE` | `writeSRE` |

Project scope is the default. For organization-wide roles and assignments,
use `-AssignmentScope organization -OrganizationId <ID>` in PowerShell, or
`--assignment-scope organization --organization-id <ID>` in Bash. This requires
organization-level custom-role and IAM administration permissions; grants are
inherited by descendant resources. The workload identity pool remains in the
configured project.

| OIDC field | Value |
| --- | --- |
| Issuer | `https://login.microsoftonline.com/<TENANT_ID>/v2.0` |
| Audience | `59f0a04a-b322-4310-adc9-39ac41e9631e` |
| `google.subject` | `assertion.tid + '::' + assertion.oid` |
| Condition | `assertion.oid == '<OBJECT_ID_1>'` or, for multiple identities, `assertion.oid == '<OBJECT_ID_1>' \|\| assertion.oid == '<OBJECT_ID_2>'` |

Compatible providers retain existing trust; custom CEL is grouped and OR-ed
with the managed OR comparisons. Identity IDs are deduplicated; conditions over
4096 characters fail.

**Trust reset:** if the issuer, audience or subject mapping differs, the condition
is missing, or custom OIDC keys are configured, setup trusts only the selected
identity. Other identities may lose access.

Setup rejects non-OIDC providers and disabled or soft-deleted resources.
Terraform can delete or replace the pool, provider and role during apply.
With approval skipped, these changes run without confirmation; GCP soft-delete
retention still applies.

**Shared role definitions, additive permissions:** each named role retains
its existing permissions and adds missing permissions from its own catalog
(plus organization-only project listing for `readSRE`). Existing titles,
descriptions, and launch stages are also left unchanged. Removing a permission
from a catalog does not revoke it from an existing role.

Manual additions affect all assignees of that role. In particular, if you
manually add a write permission to `readSRE`, it remains available to identities
assigned only that role; the `read-only` selection does not sanitize custom
permissions. Review existing permissions and the plan before applying.

### Downgrades and migration from `SREAgentRole`

Rerunning with `read-only` removes the selected identity's unconditional
`writeSRE` membership at the selected scope. Other identities' memberships
are preserved. Rerunning with `read-write` ensures both memberships exist.

For either mode, setup replaces the selected identity's unconditional legacy
`SREAgentRole` membership with the requested new memberships. The legacy role
and its other assignees are left unchanged. If a conditional `writeSRE` grant
must be removed, or a conditional legacy grant must be migrated, setup stops
before applying changes and asks you to resolve that grant through your
approved process.

**Boundary:** setup does not revoke unrelated roles, grants at other scopes,
or access inherited from an organization, folder, or group. A `read-only`
selection therefore guarantees only the assignments managed here, not the
identity's total effective access. Review inherited and external grants
separately. No running workload is changed by setup, but write permissions
allow workload changes; use your production approval and rollout process.

## State and reruns

Workspace cleanup runs on success, cancellation and apply failure.
`workspace delete -force` discards state, not cloud resources. Cleanup failure
retains the local directory/state and reports its path. Failed applies can leave
partial cloud changes; rerun to rediscover/import them.

Terraform now returns `assigned_role_names` (a list) instead of the legacy
single `role_name` output. Direct Terraform users with retained legacy state
must migrate the selected membership and retire its old state/configuration
through their normal reviewed workflow; do not apply this configuration over
an old shared-role state without reviewing deletions.

The scripts pass a per-role `existing_role_permissions` map into Terraform.
Direct Terraform users must populate this map from the live roles before each
apply to preserve manual permission additions. Run setup sequentially and do
not edit roles between discovery and apply: the union uses the discovery
snapshot, not a transaction that merges concurrent role edits.

## Local regression checks

`terraform init` followed by `terraform test` runs the mocked project and
organization role/assignment tests without changing cloud resources.
`python tests/test_setup.py` exercises both setup entry points using local
CLI doubles, including per-role permission preservation, invalid permission
responses, legacy migration, downgrades, conditional grants, and import
failures. The script tests require Python, PowerShell 7, Bash, and `jq`
on `PATH`; they do not require Azure or GCP credentials.

## References

- [Azure CLI identity lookup](https://learn.microsoft.com/cli/azure/identity#az-identity-show)
- [gcloud configured project](https://cloud.google.com/sdk/gcloud/reference/config/get)
- [Google Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [Additive Terraform IAM members](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_iam)
- [Terraform import and subsequent deletion of resources absent from configuration](https://developer.hashicorp.com/terraform/cli/import/usage)
- [Terraform Google provider authentication](https://registry.terraform.io/providers/hashicorp/google/latest/docs/guides/provider_reference)
- [Terraform workspace deletion semantics](https://developer.hashicorp.com/terraform/cli/commands/workspace/delete)
