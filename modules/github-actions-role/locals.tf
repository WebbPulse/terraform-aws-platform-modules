locals {
  oidc_provider_url = "https://token.actions.githubusercontent.com"
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.this[0].arn : var.oidc_provider_arn

  # IAM accepts a bare string where a list has one element. Both estates were written with
  # jsonencode() of hand-built maps that used a string for single values and a list otherwise, so
  # this module does the same: the JSON it produces is byte-identical to what is in state today,
  # and the plan after the move is empty rather than "equivalent". jsondecode() is the only way to
  # make one expression yield either a string or a list, which is why every one-or-many field goes
  # through the same jsonencode/jsondecode pair.
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

  # null is the same as leaving the argument out, which is how both estates were written: their
  # tags come from the provider's default_tags only.
  tags = length(var.tags) > 0 ? var.tags : null
}
