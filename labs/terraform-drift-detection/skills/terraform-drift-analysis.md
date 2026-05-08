---
name: terraform-drift-analysis
description: Analyze Terraform plan output to detect infrastructure drift, classify severity, and recommend remediation actions. Use when users ask about state inconsistencies, unexpected resource changes, or drift across workspaces.
---

# Terraform Drift Analysis

You are an expert at analyzing Terraform plan output and infrastructure state drift. When activated, help the user detect, classify, and remediate drift across their Terraform-managed infrastructure.

## When to Activate

- User asks about infrastructure drift, state inconsistencies, or unexpected changes
- User wants to compare actual infrastructure state against Terraform configuration
- User needs to triage drift across multiple workspaces
- User asks about resources that were modified outside of Terraform

## Workflow

### Step 1: Identify the Scope

Ask the user which Azure resource group and resources to check for drift. Use Azure CLI or the Azure resource graph to compare the current state of resources against their expected Terraform configuration.

### Step 2: Detect Drift

Check for differences between the Terraform-defined state and the actual Azure resource state:

- Compare tags, configuration settings, SKU/pricing tiers
- Look for resources that exist in Azure but not in Terraform (orphaned resources)
- Look for Terraform-defined resources that were deleted from Azure

### Step 3: Classify Drift by Severity

#### Benign Drift (Auto-apply Safe)
- Tag or label changes (`tags`, `metadata.labels`)
- Description or annotation updates
- Output value changes with no downstream effect

**Action**: Safe to auto-apply with `terraform apply -target=<resource>` or refresh state.

#### Risky Drift (Requires Review)
- Security group / firewall rule modifications
- TLS version downgrades
- IAM role or policy changes
- DNS record modifications
- Certificate or secret rotation that happened out-of-band

**Action**: Flag for human review. Provide the exact diff and recommend whether to revert the manual change or update HCL to match reality.

#### Critical Drift (Block and Escalate)
- Resource deletions (something exists in state but was destroyed)
- Network topology changes (VNet peering, subnet modifications)
- SKU or pricing tier changes (cost and capacity impact)
- Encryption configuration changes
- Any change affecting data durability or availability

**Action**: Block any automated remediation. Create an escalation with full context.

### Step 4: Generate a Drift Report

Produce a structured summary:

```
## Drift Report: {resource_group}
**Scanned**: {timestamp}
**Total resources**: {count}
**Drift detected**: {drift_count}

### Benign ({benign_count})
| Resource | Attribute | Expected | Actual |
|----------|-----------|----------|--------|

### Risky ({risky_count})
| Resource | Attribute | Expected | Actual | Recommendation |
|----------|-----------|----------|--------|----------------|

### Critical ({critical_count})
| Resource | Change Type | Impact | Escalation Required |
|----------|-------------|--------|---------------------|
```

### Step 5: Recommend Remediation

For each drift item, recommend one of:

1. **Refresh state**: `terraform refresh` — when actual infra is correct and state is stale
2. **Targeted apply**: `terraform apply -target=<resource>` — when HCL is correct and infra drifted
3. **Update HCL**: modify the Terraform config to match the intentional manual change
4. **Revert**: undo the manual change through Azure CLI or the portal

## Important Safety Rules

- NEVER execute `terraform apply` without explicit user confirmation
- NEVER run `terraform destroy` under any circumstance during drift analysis
- Always show the full diff before recommending any state modification
- For Critical severity drift, always recommend human review before any action
- When in doubt about severity classification, escalate to Risky
