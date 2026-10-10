resource "aws_iam_role" "this" {
  name                 = var.role_name
  path                 = var.role_path
  description          = var.role_description
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = var.audience
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.trust_subjects
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "this" {
  count = length(local.all_policy_statements) > 0 ? 1 : 0

  name = var.inline_policy_name
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.all_policy_statements
  })

  lifecycle {
    precondition {
      condition     = length(distinct(local.all_statement_sids)) == length(local.all_statement_sids)
      error_message = "A policy_statements sid collides with a preset statement's sid. The presets use LambdaImageDeploy, LambdaSmokeInvoke, EcrAuth, EcrPush, EcrPull, SpaSync and SpaInvalidate; rename the hand written statement, or drop it when the preset already grants it."
    }
  }
}
