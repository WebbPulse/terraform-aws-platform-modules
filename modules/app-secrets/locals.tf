locals {
  secret_names = {
    for k, s in var.secrets :
    k => s.name != null ? s.name : (var.name_prefix == "" ? k : "${var.name_prefix}${var.name_separator}${k}")
  }

  generated_keys = toset([for k, s in var.secrets : k if s.generate])

  json_generate_keys = toset([for k, s in var.secrets : k if length(s.json_generate) > 0])

  json_generate_entries = merge([
    for k, s in var.secrets : {
      for jk, g in s.json_generate :
      "${k}.${jk}" => { secret = k, key = jk, spec = g }
    }
  ]...)

  json_generate_bytes_entries    = { for ek, e in local.json_generate_entries : ek => e if e.spec.format == "bytes32-base64" }
  json_generate_password_entries = { for ek, e in local.json_generate_entries : ek => e if e.spec.format == "password" }

  json_generate_fresh = {
    for ek, e in local.json_generate_entries :
    ek => (
      e.spec.format == "bytes32-base64" ?
      ephemeral.random_bytes.json_generate[ek].base64 :
      ephemeral.random_password.json_generate[ek].result
    )
  }

  preserve_keys = toset([for k, s in var.secrets : k if s.json_preserve_unmanaged])

  preserve_existing_keys = toset([
    for k in local.preserve_keys :
    k if contains(data.aws_secretsmanager_secrets.preserve[k].names, local.secret_names[k])
  ])

  preserve_current_keys = toset([
    for k in local.preserve_existing_keys :
    k if anytrue([for v in data.aws_secretsmanager_secret_versions.preserve[k].versions : contains(v.version_stages, "AWSCURRENT")])
  ])

  json_generate_carry = {
    for k in local.json_generate_keys :
    k => {
      for jk, g in var.secrets[k].json_generate :
      jk => g.keep && (contains(local.preserve_keys, k) ? contains(local.preserve_current_keys, k) : var.json_generate_carry_enabled)
    }
  }

  json_generate_carry_keys = toset([
    for k in local.json_generate_keys :
    k if anytrue(values(local.json_generate_carry[k]))
  ])

  current_read_keys = setunion(local.json_generate_carry_keys, local.preserve_current_keys)

  current_json = {
    for k in local.current_read_keys :
    k => jsondecode(ephemeral.aws_secretsmanager_secret_version.current[k].secret_string)
  }

  preserved_json = { for k in local.preserve_current_keys : k => local.current_json[k] }

  has_version = {
    for k, s in var.secrets :
    k => nonsensitive(s.generate || (s.value != null && s.value != "") || s.json != null || length(s.json_generate) > 0 || s.placeholder != null || s.json_preserve_unmanaged || var.create_empty_version)
  }

  static_json_maps = {
    for k, s in var.secrets :
    k => { for jk, jv in coalesce(s.json, {}) : jk => jv if jv != null }
  }

  static_version_strings = {
    for k, s in var.secrets :
    k => (
      s.value != null ? s.value :
      s.json != null || s.json_preserve_unmanaged ? jsonencode(local.static_json_maps[k]) :
      s.placeholder != null ? s.placeholder :
      ""
    )
    if local.has_version[k]
  }

  placeholder_keys = toset([for k, s in var.secrets : k if s.placeholder != null])
  managed_keys = toset([
    for k, _ in local.static_version_strings :
    k if !contains(local.placeholder_keys, k) && !contains(local.json_generate_keys, k)
  ])

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
