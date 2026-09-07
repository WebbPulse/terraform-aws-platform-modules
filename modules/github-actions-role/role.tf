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
  count = length(var.policy_statements) > 0 ? 1 : 0

  name = var.inline_policy_name
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policy_statements
  })
}
