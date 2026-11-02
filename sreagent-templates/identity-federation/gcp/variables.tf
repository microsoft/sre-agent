variable "project_id" {
  description = "GCP project ID read from the active gcloud configuration by setup.ps1."
  type        = string
}

variable "project_number" {
  description = "Numeric identifier of the project hosting the workload identity pool."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be numeric."
  }
}

variable "azure_tenant_id" {
  description = "Azure tenant ID resolved from the user-assigned managed identity."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.azure_tenant_id))
    error_message = "azure_tenant_id must be a UUID."
  }
}

variable "uami_object_id" {
  description = "Managed identity principal/object ID, not its client ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.uami_object_id))
    error_message = "uami_object_id must be a UUID."
  }
}

variable "attribute_condition" {
  description = "Provider condition calculated by setup.ps1 from the live provider and selected identity."
  type        = string

  validation {
    condition     = length(trimspace(var.attribute_condition)) > 0 && length(var.attribute_condition) <= 4096
    error_message = "attribute_condition must contain 1-4096 characters."
  }
}

variable "existing_role_permissions" {
  description = "Live permissions fetched separately for each existing custom role by the setup scripts; preserved when adding catalog permissions."
  type        = map(set(string))
  default     = {}

  validation {
    condition     = alltrue([for id in keys(var.existing_role_permissions) : contains(["readSRE", "writeSRE"], id)])
    error_message = "existing_role_permissions keys must be readSRE or writeSRE."
  }
}

variable "access_mode" {
  description = "Assign readSRE for read-only access, or readSRE and writeSRE separately for read-write access."
  type        = string
  default     = "read-only"

  validation {
    condition     = contains(["read-only", "read-write"], var.access_mode)
    error_message = "access_mode must be read-only or read-write."
  }
}

variable "assignment_scope" {
  description = "Create the custom role and additive IAM member at project or organization scope."
  type        = string
  default     = "project"

  validation {
    condition     = contains(["project", "organization"], var.assignment_scope)
    error_message = "assignment_scope must be project or organization."
  }
}

variable "organization_id" {
  description = "Numeric organization ID, required for organization scope."
  type        = string
  default     = ""

  validation {
    condition     = var.organization_id == "" || can(regex("^[0-9]+$", var.organization_id))
    error_message = "organization_id must be empty or numeric."
  }
}
