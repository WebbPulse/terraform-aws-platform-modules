locals {
  secret_names = {
    for k, s in var.secrets :
    k => s.name != null ? s.name : (var.name_prefix == "" ? k : "${var.name_prefix}${var.name_separator}${k}")
  }

  generated_keys = toset([for k, s in var.secrets : k if s.generate])

  has_version = {
    for k, s in var.secrets :
    k => nonsensitive(s.generate || (s.value != null && s.value != "") || s.json != null || s.placeholder != null || var.create_empty_version)
  }

  static_version_strings = {
    for k, s in var.secrets :
    k => (
      s.value != null ? s.value :
      s.json != null ? jsonencode({ for jk, jv in s.json : jk => jv if jv != null }) :
      s.placeholder != null ? s.placeholder :
      ""
    )
    if local.has_version[k]
  }

  placeholder_keys = toset([for k, s in var.secrets : k if s.placeholder != null])
  managed_keys     = toset([for k, _ in local.static_version_strings : k if !contains(local.placeholder_keys, k)])

  secret_arns = { for k, r in aws_secretsmanager_secret.this : k => r.arn }

  policy_keys = var.policy_secret_keys == null ? keys(var.secrets) : var.policy_secret_keys
  policy_resources = sort([
    for k in local.policy_keys : aws_secretsmanager_secret.this[k].arn
  ])

  policy_statement = merge(
    var.policy_sid == null ? {} : { Sid = var.policy_sid },
    {
      Effect   = "Allow"
      Action   = jsondecode(length(var.policy_actions) == 1 ? jsonencode(var.policy_actions[0]) : jsonencode(var.policy_actions))
      Resource = jsondecode(length(local.policy_resources) == 1 ? jsonencode(local.policy_resources[0]) : jsonencode(local.policy_resources))
    },
  )

  read_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.policy_statement]
  })
}
