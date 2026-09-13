resource "aws_dynamodb_table" "this" {
  for_each = var.tables

  name         = local.table_names[each.key]
  billing_mode = var.billing_mode
  hash_key     = each.value.hash_key
  range_key    = each.value.range_key

  read_capacity  = var.read_capacity
  write_capacity = var.write_capacity

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
      projection_type    = global_secondary_index.value.projection_type
      non_key_attributes = global_secondary_index.value.non_key_attributes
      read_capacity      = global_secondary_index.value.read_capacity
      write_capacity     = global_secondary_index.value.write_capacity

      key_schema {
        attribute_name = global_secondary_index.value.hash_key
        key_type       = "HASH"
      }

      dynamic "key_schema" {
        for_each = global_secondary_index.value.range_key == null ? [] : [global_secondary_index.value.range_key]

        content {
          attribute_name = key_schema.value
          key_type       = "RANGE"
        }
      }
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

  stream_enabled   = local.stream_enabled[each.key]
  stream_view_type = local.stream_view_type[each.key]

  deletion_protection_enabled = coalesce(each.value.deletion_protection, var.deletion_protection)

  tags = length(local.table_tags[each.key]) == 0 ? null : local.table_tags[each.key]
}
