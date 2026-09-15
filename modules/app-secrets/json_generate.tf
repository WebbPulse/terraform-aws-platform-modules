ephemeral "random_bytes" "json_generate" {
  for_each = local.json_generate_bytes_entries

  length = 32
}

ephemeral "random_password" "json_generate" {
  for_each = local.json_generate_password_entries

  length           = each.value.spec.length
  special          = each.value.spec.special
  override_special = each.value.spec.override_special
  min_special      = each.value.spec.min_special
  min_numeric      = each.value.spec.min_numeric
  min_upper        = each.value.spec.min_upper
  min_lower        = each.value.spec.min_lower
}

ephemeral "aws_secretsmanager_secret_version" "json_generate" {
  for_each = local.json_generate_carry_keys

  secret_id = aws_secretsmanager_secret.this[each.key].id
}

resource "aws_secretsmanager_secret_version" "json_generate" {
  for_each = local.json_generate_keys

  secret_id = aws_secretsmanager_secret.this[each.key].id

  secret_string_wo = jsonencode(merge(
    local.static_json_maps[each.key],
    {
      for jk, g in var.secrets[each.key].json_generate :
      jk => (
        local.json_generate_carry[each.key][jk] ?
        lookup(
          jsondecode(ephemeral.aws_secretsmanager_secret_version.json_generate[each.key].secret_string),
          jk,
          local.json_generate_fresh["${each.key}.${jk}"],
        ) :
        local.json_generate_fresh["${each.key}.${jk}"]
      )
    },
  ))
  secret_string_wo_version = var.secrets[each.key].version
}
