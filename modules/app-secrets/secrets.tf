ephemeral "random_password" "this" {
  for_each = local.generated_keys

  length           = var.secrets[each.key].generate_length
  special          = var.secrets[each.key].generate_special
  override_special = var.secrets[each.key].generate_override_special
  min_special      = var.secrets[each.key].generate_min_special
  min_numeric      = var.secrets[each.key].generate_min_numeric
  min_upper        = var.secrets[each.key].generate_min_upper
  min_lower        = var.secrets[each.key].generate_min_lower
}

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name                    = local.secret_names[each.key]
  description             = each.value.description != null ? each.value.description : var.description_default
  recovery_window_in_days = each.value.recovery_window_in_days != null ? each.value.recovery_window_in_days : var.recovery_window_in_days
  kms_key_id              = each.value.kms_key_id != null ? each.value.kms_key_id : var.kms_key_id

  tags = merge(var.tags, each.value.tags)
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = local.managed_keys

  secret_id = aws_secretsmanager_secret.this[each.key].id

  secret_string_wo = (
    var.secrets[each.key].generate ? ephemeral.random_password.this[each.key].result :
    contains(local.preserve_keys, each.key) ? jsonencode(merge(lookup(local.preserved_json, each.key, {}), local.static_json_maps[each.key])) :
    local.static_version_strings[each.key]
  )
  secret_string_wo_version = var.secrets[each.key].version
}

resource "aws_secretsmanager_secret_version" "placeholder" {
  for_each = local.placeholder_keys

  secret_id = aws_secretsmanager_secret.this[each.key].id

  secret_string_wo         = local.static_version_strings[each.key]
  secret_string_wo_version = var.secrets[each.key].version

  lifecycle {
    ignore_changes = [secret_string_wo_version, version_stages]
  }
}
