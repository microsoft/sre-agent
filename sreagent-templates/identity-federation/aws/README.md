# SRE Agent AWS connector setup

This package uses Terraform to configure the AWS OIDC provider,
`SREAgentRole`, AWS MCP OAuth permission and workload policy required by the
SRE Agent AWS connector.

An Agent resource ID uses its system-assigned managed identity. To use a
user-assigned managed identity, provide that identity's own ARM resource ID.

## Prerequisites

The following tools are required:

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Terraform 1.7 or later](https://developer.hashicorp.com/terraform/install)
- [`jq`](https://jqlang.org/download/) on Linux and macOS

Install the tools by following their official documentation links above before
running the setup. The setup scripts validate that Terraform is a stable
version 1.7 or later and that AWS CLI v2 provides
`signin create-oauth2-token-with-iam`.

### Verify the installation

```text
az version
aws --version
terraform version
```

Linux and macOS customers should also run:

```text
jq --version
```

## Windows

### 1. Login

Open PowerShell in the directory containing this README and the Terraform
files:

```powershell
az login
aws login
```

If your organization uses AWS SSO or another AWS authentication method, use
that instead of `aws login`. Terraform uses the active AWS credentials.

### 2. Run the setup script

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
```

When prompted:

1. Enter the full ARM resource ID of the managed identity or SRE Agent.
2. Select `read-only` or `read-write` from the displayed permission levels.
3. Review the selected policies, their descriptions and the discovered identity, once confirmed enter `y` to apply or `n` to cancel.

For unattended execution:

```powershell
.\setup.ps1 `
    -ResourceId '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/my-group/providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-identity' `
    -allowed-permissions read-write `
    -skip-approval true
```

## Linux or macOS

### 1. Login

Open Bash in the directory containing this README and the Terraform files:

```bash
az login
aws login
```

If your organization uses AWS SSO or another AWS authentication method, use
that instead of `aws login`. Terraform uses the active AWS credentials.

### 2. Run the setup script

```bash
chmod +x setup.sh
./setup.sh
```

When prompted:

1. Enter the full ARM resource ID of the managed identity or SRE Agent.
2. Select `read-only` or `read-write` from the displayed permission levels.
3. Review the selected policies, their descriptions and the discovered identity, once confirmed enter `y` to apply or `n` to cancel.

For unattended execution:

```bash
./setup.sh \
  --resource-id '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/my-group/providers/Microsoft.App/agents/my-agent' \
  --allowed-permissions=read-write \
  --skip-approval=true
```

## Sample SREAgent workload policies

The following samples are ready-to-use, account-wide permission sets with no
resource placeholders. They target common investigation and operational tasks,
not every AWS service or every possible debugging operation. They do not grant
AWS's `aidevops:*` product-management permissions.

| Sample policy | What it enables | Intended use |
| --- | --- | --- |
| [`SREAgentReadOnlyAccess`](SREAgentReadOnlyAccess.json) | Inspect AWS resources, IAM configuration, logs, metrics and traces; run diagnostic queries; list and read S3 objects and versions, DynamoDB items, Parameter Store values and Secrets Manager secrets; decrypt data with KMS; inspect Systems Manager connection status. | Standalone investigation and data-read policy. Includes sensitive data and credential access, but no interactive execution or database connections. |
| [`SREAgentWriteAccess`](SREAgentWriteAccess.json) | Open ECS Exec and Systems Manager sessions, access the EKS Kubernetes API and connect through RDS IAM authentication; start, stop and reboot EC2/RDS resources; reboot ElastiCache clusters; adjust scaling, ECS services, EKS node groups and Lambda concurrency; invalidate CloudFront caches; stop or redrive Step Functions executions. | Optional write and interactive-debugging supplement to ReadOnlyAccess. These permissions apply to every identity trusted by the role. |

## What the setup script does

- Reads the selected managed identity Tenant ID, Client ID and Principal ID
  from Azure
- Reads the active AWS account ID
- Checks the tenant's shared IAM OIDC provider
- Imports that provider into the local Terraform state when it already exists
- Preserves every existing provider audience and adds the selected managed
  identity Client ID when missing
- Checks `SREAgentRole` and imports it into the local Terraform state when it
  already exists
- Preserves the role's existing trust statements and adds one separate
  statement for the selected managed identity
- Writes those identity values to a local Terraform variables file
- Runs `terraform init`
- Runs `terraform plan`
- Creates or updates the tenant OIDC provider through Terraform
- Creates or updates `SREAgentRole` through Terraform
- Configures its web-identity trust policy
- Attaches `AWSMCPSignInOAuthAccessPolicy`
- Creates or updates `SREAgentReadOnlyAccess`, and `SREAgentWriteAccess` only
  for `read-write`