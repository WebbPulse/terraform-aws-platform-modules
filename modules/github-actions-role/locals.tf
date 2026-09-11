locals {
  oidc_provider_url = "https://token.actions.githubusercontent.com"
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.this[0].arn : var.oidc_provider_arn

  trust_subjects = jsondecode(length(var.subjects) == 1 ? jsonencode(var.subjects[0]) : jsonencode(var.subjects))

  policy_statements = [
    for s in var.policy_statements : merge(
      { Effect = s.effect },
      s.actions == null ? {} : { Action = jsondecode(length(s.actions) == 1 ? jsonencode(s.actions[0]) : jsonencode(s.actions)) },
      s.not_actions == null ? {} : { NotAction = jsondecode(length(s.not_actions) == 1 ? jsonencode(s.not_actions[0]) : jsonencode(s.not_actions)) },
      s.resources == null ? {} : { Resource = jsondecode(length(s.resources) == 1 ? jsonencode(s.resources[0]) : jsonencode(s.resources)) },
      s.not_resources == null ? {} : { NotResource = jsondecode(length(s.not_resources) == 1 ? jsonencode(s.not_resources[0]) : jsonencode(s.not_resources)) },
      s.sid == null ? {} : { Sid = s.sid },
      s.condition == null ? {} : {
        Condition = {
          for op, kv in s.condition : op => {
            for k, v in kv : k => jsondecode(length(v) == 1 ? jsonencode(v[0]) : jsonencode(v))
          }
        }
      },
    )
  ]

  tags = length(var.tags) > 0 ? var.tags : null
}
