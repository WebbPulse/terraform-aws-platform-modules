# ---------------------------------------------------------------------------
# The identity tables.
#
# Per entity rather than single table, which section 4.1 of the identity standard settles against
# the fashionable default. The deciding argument is TTL: it is a table-level setting, refresh
# tokens and verification tokens want one, and credentials must never have one. Mixing an expiring
# entity and a permanent one in a single table means the permanent items carry a TTL attribute that
# must never be set, and one bug silently deletes accounts. Separate tables make that failure
# impossible rather than merely unlikely. Per-table IAM is the other half: one identity table would
# have to be granted to both the identity and the users domains, weakening the boundary the domain
# split exists to draw.
#
# The keys are the package's contract, not this module's preference. webbpulse.identity.storage and
# webbpulse.identity.lockout write these exact attribute names, and a table whose hash key does not
# match what the store writes fails at request time rather than at apply time. The default var.tables
# map reproduces them; changing a key there is changing the package's storage layer.
#
# This deliberately does not call the dynamodb-tables module. Nothing under modules/ references a
# sibling by relative path, and consuming it through the registry would pin this module to a
# published version of another one in the same repository, which a single tag cannot express.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "this" {
  for_each = var.tables

  name         = local.table_names[each.key]
  billing_mode = var.billing_mode
  hash_key     = each.value.hash_key
  range_key    = each.value.range_key

  # Every key attribute the table or one of its indexes uses, and only those: DynamoDB rejects an
  # attribute that no key references and requires one for every key. The provider stores this as a
  # set, so the order the consumer writes them in does not reach the plan.
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

  # TTL is storage reclamation and never an access control. DynamoDB deletes expired items on its
  # own schedule, typically within a couple of days, so every one of these deadlines is also
  # checked against the clock on read by the package. Turning TTL off here does not make an expired
  # token valid; it only stops the rows being reclaimed.
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

# The table grant, as one statement covering every table this module created and every index on
# them. The index wildcard is not optional: the refresh token family query reads
# family_id-generation-index, and a policy naming only the table ARNs denies it.
resource "aws_iam_role_policy" "identity_tables" {
  count = var.identity_role_name == null || length(var.tables) == 0 ? 0 : 1

  name   = "identity-tables"
  role   = var.identity_role_name
  policy = local.table_policy_json
}
