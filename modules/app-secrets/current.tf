data "aws_secretsmanager_secrets" "preserve" {
  for_each = local.preserve_keys

  filter {
    name   = "name"
    values = [local.secret_names[each.key]]
  }
}

data "aws_secretsmanager_secret_versions" "preserve" {
  for_each = local.preserve_existing_keys

  secret_id = local.secret_names[each.key]
}

ephemeral "aws_secretsmanager_secret_version" "current" {
  for_each = local.current_read_keys

  secret_id = aws_secretsmanager_secret.this[each.key].id
}
