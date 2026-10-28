locals {
  azure_sre_application_id = "59f0a04a-b322-4310-adc9-39ac41e9631e"
  aws_mcp_signin_policy    = "arn:aws:iam::aws:policy/AWSMCPSignInOAuthAccessPolicy"

  entra_issuer            = "https://login.microsoftonline.com/${var.managed_identity.tenant_id}/v2.0"
  issuer_condition_prefix = trimprefix(local.entra_issuer, "https://")

  oidc_provider_audiences = sort(distinct(concat(
    [var.managed_identity.client_id],
    tolist(var.additional_oidc_provider_audiences)
  )))

  trust_string_equals = {
    "${local.issuer_condition_prefix}:aud"  = var.managed_identity.client_id
    "${local.issuer_condition_prefix}:oaud" = local.azure_sre_application_id
    "${local.issuer_condition_prefix}:sub"  = var.managed_identity.principal_id
  }

  managed_identity_trust_statement = {
    Sid       = "TrustManagedIdentity${replace(lower(var.managed_identity.client_id), "-", "")}"
    Effect    = "Allow"
    Action    = "sts:AssumeRoleWithWebIdentity"
    Principal = { Federated = aws_iam_openid_connect_provider.entra.arn }
    Condition = { StringEquals = local.trust_string_equals }
  }

  role_trust_statements = concat(
    var.existing_role_trust_statements,
    [local.managed_identity_trust_statement]
  )

  role_policy_arns = setunion(var.policy_arns, toset([local.aws_mcp_signin_policy]))
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "terraform_data" "configuration_validation" {
  input = {
    aws_account_id     = data.aws_caller_identity.current.account_id
    identity_type      = var.managed_identity.type
    identity_resource  = var.managed_identity.resource_id
    provider_audiences = local.oidc_provider_audiences
  }

  lifecycle {
    precondition {
      condition     = data.aws_partition.current.partition == "aws"
      error_message = "This setup supports the commercial AWS partition only."
    }

    precondition {
      condition     = length(local.oidc_provider_audiences) <= 100
      error_message = "An IAM OIDC provider supports at most 100 client IDs."
    }
  }
}

resource "aws_iam_openid_connect_provider" "entra" {
  url            = local.entra_issuer
  client_id_list = local.oidc_provider_audiences

  depends_on = [terraform_data.configuration_validation]

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_iam_role" "entra" {
  name                 = var.role_name
  path                 = var.role_path
  description          = var.role_description
  max_session_duration = var.max_session_duration

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.role_trust_statements
  })

  lifecycle {
    ignore_changes = [
      permissions_boundary,
      tags,
    ]
  }
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = local.role_policy_arns

  role       = aws_iam_role.entra.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "workload" {
  for_each = var.workload_policies

  name   = each.key
  role   = aws_iam_role.entra.id
  policy = jsonencode(each.value)
}
