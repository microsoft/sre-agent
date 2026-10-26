variable "managed_identity" {
  description = "Azure managed identity facts used to configure the AWS OIDC trust."
  type = object({
    type         = string
    resource_id  = string
    name         = string
    tenant_id    = string
    client_id    = string
    principal_id = string
  })
  nullable = false

  validation {
    condition     = contains(["UserAssigned", "SystemAssigned"], var.managed_identity.type)
    error_message = "managed_identity.type must be UserAssigned or SystemAssigned."
  }

  validation {
    condition = (
      var.managed_identity.type == "UserAssigned"
      ? can(regex(
        "(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$",
        var.managed_identity.resource_id
      ))
      : can(regex(
        "(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourceGroups/[^/]+/providers/Microsoft\\.App/agents/[^/]+$",
        var.managed_identity.resource_id
      ))
    )
    error_message = "managed_identity.resource_id must match the selected identity type."
  }

  validation {
    condition = alltrue([
      for value in [
        var.managed_identity.tenant_id,
        var.managed_identity.client_id,
        var.managed_identity.principal_id,
      ] :
      can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", value))
    ])
    error_message = "managed_identity tenant_id, client_id, and principal_id must be UUIDs."
  }

  validation {
    condition     = length(trimspace(var.managed_identity.name)) > 0
    error_message = "managed_identity.name must not be empty."
  }
}

variable "role_name" {
  description = "Name of the AWS IAM role used by the SRE Agent AWS connector."
  type        = string
  default     = "SREAgentRole"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be 1-64 characters using AWS IAM role-name characters."
  }
}

variable "role_path" {
  description = "IAM path assigned to the role."
  type        = string
  default     = "/"

  validation {
    condition = (
      var.role_path == "/"
      || (
        length(var.role_path) <= 512
        && can(regex("^/[!-~]+/$", var.role_path))
      )
    )
    error_message = "role_path must be / or an AWS IAM path of at most 512 printable ASCII characters."
  }
}

variable "role_description" {
  description = "Description assigned to the IAM role."
  type        = string
  default     = "Assumed by an Azure managed identity through Microsoft Entra OIDC federation."
}

variable "max_session_duration" {
  description = "Maximum role session duration in seconds."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds."
  }
}

variable "existing_role_trust_statements" {
  description = "Existing IAM role trust-policy statements to preserve when adding the selected managed identity."
  type        = any
  default     = []
}

variable "additional_oidc_provider_audiences" {
  description = "Additional client IDs to register when this Terraform state owns a shared OIDC provider."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for audience in var.additional_oidc_provider_audiences :
      length(audience) >= 1 && length(audience) <= 255
    ])
    error_message = "Each additional OIDC provider audience must contain 1-255 characters."
  }
}

variable "policy_arns" {
  description = "Additional AWS managed or customer-managed policies attached to the role. AWSMCPSignInOAuthAccessPolicy is always attached."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.policy_arns :
      can(regex("^arn:[^:]+:iam::([0-9]{12}|aws):policy/.+$", arn))
    ])
    error_message = "Each policy_arns value must be an AWS managed or customer-managed IAM policy ARN."
  }
}

variable "workload_policies" {
  description = "Inline IAM policies keyed by their names. Specify the desired policies explicitly."
  type        = any
  nullable    = false

  validation {
    condition = (
      can(keys(var.workload_policies))
      && try(alltrue([
        for name, policy in var.workload_policies :
        can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", name))
        && policy.Version == "2012-10-17"
        && length(policy.Statement) > 0
      ]), false)
    )
    error_message = "workload_policies must map valid IAM policy names to policy objects containing Version 2012-10-17 and nonempty Statement."
  }

  validation {
    condition     = try(sum([for policy in values(var.workload_policies) : length(jsonencode(policy))]) <= 10240, false)
    error_message = "The workload policies exceed the 10,240-character aggregate role inline-policy limit."
  }
}
