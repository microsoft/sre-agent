mock_provider "google" {}

variables {
  project_id          = "sre-test-project"
  project_number      = "123456789012"
  azure_tenant_id     = "11111111-1111-1111-1111-111111111111"
  uami_object_id      = "22222222-2222-2222-2222-222222222222"
  attribute_condition = "assertion.oid == '22222222-2222-2222-2222-222222222222'"
}

run "project_read_only" {
  command = apply

  assert {
    condition     = toset(keys(google_project_iam_custom_role.sre_agent)) == toset(["readSRE", "writeSRE"])
    error_message = "Both project custom roles must exist even for read-only access."
  }

  assert {
    condition     = toset(keys(google_project_iam_member.sre_agent)) == toset(["readSRE"]) && length(google_organization_iam_member.sre_agent) == 0
    error_message = "Read-only must assign only readSRE at the selected scope."
  }

  assert {
    condition = (
      google_project_iam_custom_role.sre_agent["readSRE"].permissions == toset(jsondecode(file("readSRE.json")).includedPermissions) &&
      google_project_iam_custom_role.sre_agent["writeSRE"].permissions == toset(jsondecode(file("writeSRE.json")).includedPermissions) &&
      length(setintersection(local.role_permissions.readSRE, local.role_permissions.writeSRE)) == 0
    )
    error_message = "Role permissions must exactly match their separate, disjoint catalogs."
  }

  assert {
    condition     = google_project_iam_member.sre_agent["readSRE"].member == local.principal_id && google_project_iam_member.sre_agent["readSRE"].role == google_project_iam_custom_role.sre_agent["readSRE"].name
    error_message = "The read role must be bound to the supplied federated identity."
  }
}

run "project_read_write" {
  command = apply

  variables {
    access_mode = "read-write"
  }

  assert {
    condition     = toset(keys(google_project_iam_member.sre_agent)) == toset(["readSRE", "writeSRE"])
    error_message = "Read-write must assign both project roles separately."
  }

  assert {
    condition     = alltrue([for id, binding in google_project_iam_member.sre_agent : binding.member == local.principal_id && binding.role == google_project_iam_custom_role.sre_agent[id].name])
    error_message = "Each role must be assigned separately to the same supplied identity."
  }

  assert {
    condition     = output.assigned_role_names == [google_project_iam_custom_role.sre_agent["readSRE"].name, google_project_iam_custom_role.sre_agent["writeSRE"].name]
    error_message = "Outputs must report both assigned roles."
  }
}

run "project_downgrade" {
  command = apply

  assert {
    condition     = toset(keys(google_project_iam_member.sre_agent)) == toset(["readSRE"]) && length(google_project_iam_custom_role.sre_agent) == 2
    error_message = "A downgrade must remove only the write membership, not its shared custom role."
  }
}

run "organization_read_write" {
  command = apply

  variables {
    access_mode      = "read-write"
    assignment_scope = "organization"
    organization_id  = "987654321"
  }

  assert {
    condition     = length(google_project_iam_custom_role.sre_agent) == 0 && length(google_project_iam_member.sre_agent) == 0 && length(google_organization_iam_custom_role.sre_agent) == 2
    error_message = "Organization mode must create both organization roles and no project roles or grants."
  }

  assert {
    condition     = toset(keys(google_organization_iam_member.sre_agent)) == toset(["readSRE", "writeSRE"]) && alltrue([for id, binding in google_organization_iam_member.sre_agent : binding.member == local.principal_id && binding.role == google_organization_iam_custom_role.sre_agent[id].name])
    error_message = "Both organization roles must be separately assigned to the supplied identity."
  }

  assert {
    condition     = google_organization_iam_custom_role.sre_agent["readSRE"].permissions == setunion(toset(jsondecode(file("readSRE.json")).includedPermissions), toset(["resourcemanager.projects.list"]))
    error_message = "Organization project discovery must be included only in the read role."
  }
}

run "organization_downgrade" {
  command = apply

  variables {
    assignment_scope = "organization"
    organization_id  = "987654321"
  }

  assert {
    condition     = toset(keys(google_organization_iam_member.sre_agent)) == toset(["readSRE"]) && length(google_organization_iam_custom_role.sre_agent) == 2
    error_message = "Organization read-only must retain both role definitions but only the read assignment."
  }
}
