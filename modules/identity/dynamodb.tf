resource "aws_dynamodb_table" "this" {
  for_each = var.tables

  name         = local.table_names[each.key]
  billing_mode = var.billing_mode
  hash_key     = each.value.hash_key
  range_key    = each.value.range_key

  dynamic "attribute" {
    for_each = each.value.attributes

    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }

  dynamic "global_secondary_index" {
    for_each = each.value.global_secondary_indexes

    content {
      name               = global_secondary_index.value.name
      hash_key           = global_secondary_index.value.hash_key
      range_key          = global_secondary_index.value.range_key
      projection_type    = global_secondary_index.value.projection_type
      non_key_attributes = global_secondary_index.value.non_key_attributes
    }
  }

  dynamic "ttl" {
    for_each = each.value.ttl_attribute == null ? [] : [each.value.ttl_attribute]

    content {
      attribute_name = ttl.value
      enabled        = true
    }
  }

  point_in_time_recovery {
    enabled = coalesce(each.value.point_in_time_recovery, var.point_in_time_recovery)
  }

  dynamic "server_side_encryption" {
    for_each = var.server_side_encryption == null ? [] : [var.server_side_encryption]

    content {
      enabled     = server_side_encryption.value.enabled
      kms_key_arn = server_side_encryption.value.kms_key_arn
    }
  }

  deletion_protection_enabled = coalesce(each.value.deletion_protection, var.deletion_protection)

  tags = length(local.table_tags[each.key]) == 0 ? null : local.table_tags[each.key]
}

resource "aws_iam_role_policy" "identity_tables" {
  count = var.attach_role_policies && length(var.tables) > 0 ? 1 : 0

  name   = "identity-tables"
  role   = var.identity_role_name
  policy = local.table_policy_json
}

resource "aws_iam_role_policy" "additional_table_grants" {
  for_each = var.additional_table_grants

  name   = "identity-tables-${each.key}"
  role   = each.value.role_name
  policy = local.additional_grant_policy_json[each.key]
}
