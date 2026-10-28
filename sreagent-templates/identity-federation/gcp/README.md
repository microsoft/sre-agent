# SRE Agent GCP connector setup

This package uses Terraform to configure the GCP Workload Identity pool,
OIDC provider, `SREAgentRole` custom IAM role, and role assignment required by
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
Follow the steps below from that folder. Keep the setup scripts and all `.tf`
files together.

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

Keep `setup.ps1` and all `.tf` files together. Replace the example resource ID:

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

Keep `setup.sh` and all `.tf` files together. Replace the example resource ID:

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
- Discovers the existing pool, provider, custom role, and role assignment for
  the selected identity. Generates Terraform import blocks for these resources
  and enabled APIs; imports the role assignment only if it has no IAM condition.
  Pool/provider imports use the configured project ID to avoid replacement;
  discovery and federated principal names use the project number.
- Extends compatible provider trust and unions existing role permissions with
  the requested [permission catalogs](./main.tf).
- Ensures IAM, Resource Manager, Service Account Credentials and STS APIs are
  enabled; applies an additive IAM member without replacing other bindings.
- Runs `terraform init` and `apply` in a unique temporary CLI workspace, then
  deletes the workspace and local files without running `terraform destroy`.

## Federation configuration

| Resource | Fixed ID | Display name |
| --- | --- | --- |
| Workload Identity pool | `sre-agent-pool` | `SREAgentPool` |
| OIDC provider | `sre-agent-provider` | `SREAgentProvider` |
| Custom IAM role | `SREAgentRole` | `SREAgentRole` |

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

**Shared permissions:** `existing UNION read UNION write` (write only for
`read-write`). All role assignees receive the union; `read-only` never downgrades
existing write access. The catalogs are not administrator roles.

## State and reruns

Workspace cleanup runs on success, cancellation and apply failure.
`workspace delete -force` discards state, not cloud resources. Cleanup failure
retains the local directory/state and reports its path. Failed applies can leave
partial cloud changes; rerun to rediscover/import them.

## References

- [Azure CLI identity lookup](https://learn.microsoft.com/cli/azure/identity#az-identity-show)
- [gcloud configured project](https://cloud.google.com/sdk/gcloud/reference/config/get)
- [Google Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [Additive Terraform IAM members](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_project_iam)
- [Terraform Google provider authentication](https://registry.terraform.io/providers/hashicorp/google/latest/docs/guides/provider_reference)
- [Terraform workspace deletion semantics](https://developer.hashicorp.com/terraform/cli/commands/workspace/delete)
