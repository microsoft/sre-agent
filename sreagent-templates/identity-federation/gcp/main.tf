provider "google" {
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
}

resource "google_project_service" "required" {
  for_each = toset([
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "sre_agent" {
  project                   = var.project_id
  workload_identity_pool_id = "sre-agent-pool"
  display_name              = "SREAgentPool"

  depends_on = [google_project_service.required]

  lifecycle {
    ignore_changes = [description]
  }
}

resource "google_iam_workload_identity_pool_provider" "azure" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.sre_agent.workload_identity_pool_id
  workload_identity_pool_provider_id = "sre-agent-provider"
  display_name                       = "SREAgentProvider"

  attribute_mapping = {
    "google.subject" = "assertion.tid + '::' + assertion.oid"
  }
  attribute_condition = var.attribute_condition

  oidc {
    issuer_uri        = "https://login.microsoftonline.com/${lower(var.azure_tenant_id)}/v2.0"
    allowed_audiences = ["59f0a04a-b322-4310-adc9-39ac41e9631e"]
  }

  lifecycle {
    ignore_changes = [description]
  }
}

locals {
  # The pool name contains its hosting project number, not the project ID.
  principal_id       = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/sre-agent-pool/subject/${lower(var.azure_tenant_id)}::${lower(var.uami_object_id)}"
  organization_scope = var.assignment_scope == "organization"
  role_definitions = {
    readSRE  = jsondecode(file("${path.module}/readSRE.json"))
    writeSRE = jsondecode(file("${path.module}/writeSRE.json"))
  }
  role_permissions = {
    for id, definition in local.role_definitions : id => setunion(
      lookup(var.existing_role_permissions, id, toset([])),
      toset(definition.includedPermissions),
      # Project listing on a parent is only applicable to organization-level roles.
      id == "readSRE" && local.organization_scope ? toset(["resourcemanager.projects.list"]) : toset([]),
    )
  }
  assigned_role_ids = var.access_mode == "read-write" ? toset(["readSRE", "writeSRE"]) : toset(["readSRE"])
}

resource "google_project_iam_custom_role" "sre_agent" {
  for_each = local.organization_scope ? {} : local.role_definitions

  project     = var.project_id
  role_id     = each.key
  title       = each.value.title
  description = each.value.description
  stage       = each.value.stage

  permissions = local.role_permissions[each.key]

  depends_on = [google_project_service.required]

  lifecycle {
    ignore_changes = [title, description, stage]
  }
}

resource "google_organization_iam_custom_role" "sre_agent" {
  for_each = local.organization_scope ? local.role_definitions : {}

  org_id      = var.organization_id
  role_id     = each.key
  title       = each.value.title
  description = each.value.description
  stage       = each.value.stage
  permissions = local.role_permissions[each.key]

  depends_on = [google_project_service.required]

  lifecycle {
    ignore_changes = [title, description, stage]

    precondition {
      condition     = var.organization_id != ""
      error_message = "organization_id is required when assignment_scope is organization."
    }
  }
}

resource "google_project_iam_member" "sre_agent" {
  for_each = local.organization_scope ? toset([]) : local.assigned_role_ids

  project = var.project_id
  role    = google_project_iam_custom_role.sre_agent[each.key].name
  member  = local.principal_id

  depends_on = [google_iam_workload_identity_pool_provider.azure]
}

resource "google_organization_iam_member" "sre_agent" {
  for_each = local.organization_scope ? local.assigned_role_ids : toset([])

  org_id = var.organization_id
  role   = google_organization_iam_custom_role.sre_agent[each.key].name
  member = local.principal_id

  depends_on = [google_iam_workload_identity_pool_provider.azure]
}

output "assigned_role_names" {
  description = "Custom roles separately assigned to the federated managed identity at the selected scope."
  value = [
    for id in sort(tolist(local.assigned_role_ids)) :
    local.organization_scope ? google_organization_iam_custom_role.sre_agent[id].name : google_project_iam_custom_role.sre_agent[id].name
  ]
}

output "workload_identity_provider" {
  description = "Full provider resource name to enter in the GCP connector."
  value       = google_iam_workload_identity_pool_provider.azure.name
}

output "principal_id" {
  description = "Federated IAM member assigned the selected custom roles."
  value       = local.principal_id
}
