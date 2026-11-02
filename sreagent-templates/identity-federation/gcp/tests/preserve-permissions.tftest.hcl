mock_provider "google" {}

variables {
  project_id          = "sre-test-project"
  project_number      = "123456789012"
  azure_tenant_id     = "11111111-1111-1111-1111-111111111111"
  uami_object_id      = "22222222-2222-2222-2222-222222222222"
  attribute_condition = "assertion.oid == '22222222-2222-2222-2222-222222222222'"
  existing_role_permissions = {
    readSRE  = ["compute.projects.get", "compute.instances.get", "compute.projects.get"]
    writeSRE = ["compute.instances.delete", "compute.instances.update"]
  }
}

run "project_preserves_each_role" {
  command = apply

  assert {
    condition = alltrue([
      for id, role in google_project_iam_custom_role.sre_agent :
      role.permissions == setunion(var.existing_role_permissions[id], toset(jsondecode(file("${id}.json")).includedPermissions))
    ])
    error_message = "Each project role must preserve its own manual permissions and add all missing catalog permissions without borrowing from the other role."
  }
}

run "project_upgrade_preserves_permissions" {
  command = apply

  variables {
    access_mode = "read-write"
  }

  assert {
    condition = alltrue([
      for id, role in google_project_iam_custom_role.sre_agent :
      role.permissions == setunion(var.existing_role_permissions[id], toset(jsondecode(file("${id}.json")).includedPermissions))
    ])
    error_message = "Changing access mode must not replace either role's permissions."
  }
}

run "organization_preserves_each_role" {
  command = apply

  variables {
    assignment_scope = "organization"
    organization_id  = "987654321"
    access_mode      = "read-write"
  }

  assert {
    condition = alltrue([
      for id, role in google_organization_iam_custom_role.sre_agent :
      role.permissions == setunion(
        var.existing_role_permissions[id],
        toset(jsondecode(file("${id}.json")).includedPermissions),
        id == "readSRE" ? toset(["resourcemanager.projects.list"]) : toset([]),
      )
    ])
    error_message = "Each organization role must preserve only its own existing permissions; project listing belongs only to readSRE."
  }
}

run "organization_downgrade_preserves_permissions" {
  command = apply

  variables {
    assignment_scope = "organization"
    organization_id  = "987654321"
  }

  assert {
    condition = alltrue([
      for id, role in google_organization_iam_custom_role.sre_agent :
      role.permissions == setunion(
        var.existing_role_permissions[id],
        toset(jsondecode(file("${id}.json")).includedPermissions),
        id == "readSRE" ? toset(["resourcemanager.projects.list"]) : toset([]),
      )
    ])
    error_message = "A downgrade must preserve manual permissions in both role definitions, including the unassigned write role."
  }
}
