# Per-table streams: a table's own stream_view_type turns that table's stream on by itself, the
# module-wide pair still drives every table that sets no value of its own, and a consumer that sets
# neither gets the streamless table it has today.
#
# The last of those is the backward compatibility guarantee and is what makes this a no plan change
# release for every existing call. The mixed case is the one the module-wide pair could not express
# at all before this change: streams on some of the tables in one call and not on the rest.

variables {
  name_prefix = "example-staging"

  tables = {
    users = {
      attributes       = [{ name = "id", type = "S" }]
      hash_key         = "id"
      stream_view_type = "NEW_AND_OLD_IMAGES"
    }

    votes = {
      attributes       = [{ name = "id", type = "S" }]
      hash_key         = "id"
      stream_view_type = "KEYS_ONLY"
    }

    sessions = {
      attributes = [{ name = "id", type = "S" }]
      hash_key   = "id"
    }
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

# Streams on two of the three tables, each carrying its own view type, and the third left exactly as
# it is. This is the whole point of the field: the module-wide pair is one value for every table the
# call creates, so it cannot leave `sessions` alone while streaming the other two.
run "per_table_value_streams_only_that_table" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["users"].stream_enabled
    error_message = "A table with a non-null stream_view_type must have its stream turned on."
  }

  assert {
    condition     = aws_dynamodb_table.this["users"].stream_view_type == "NEW_AND_OLD_IMAGES"
    error_message = "A table's own stream_view_type must reach the resource unchanged."
  }

  assert {
    condition     = aws_dynamodb_table.this["votes"].stream_view_type == "KEYS_ONLY"
    error_message = "Each table carries its own view type; they do not have to agree."
  }

  assert {
    condition     = !aws_dynamodb_table.this["sessions"].stream_enabled
    error_message = "A table that sets no stream_view_type must not be streamed by another table's value."
  }

  # stream_view_type is not asserted on the streamless table: the provider marks it computed when
  # the stream is off, so it is unknown at plan time. stream_enabled is the flag that decides
  # whether a stream exists at all, and it is known, so it is the one worth pinning.
}

# The backward compatibility guarantee. Neither the module-wide pair nor any per-table value is set,
# which is every existing consumer, and no table may gain a stream.
run "no_stream_anywhere_by_default" {
  command = plan

  variables {
    tables = {
      users = {
        attributes = [{ name = "id", type = "S" }]
        hash_key   = "id"
      }
      sessions = {
        attributes = [{ name = "id", type = "S" }]
        hash_key   = "id"
      }
    }
  }

  assert {
    condition = alltrue([
      for name, table in aws_dynamodb_table.this : !table.stream_enabled
    ])
    error_message = "With no module-wide and no per-table value set, no table may have a stream."
  }
}

# The module-wide pair still works and still reaches every table that sets no value of its own.
run "module_wide_pair_still_applies_to_all" {
  command = plan

  variables {
    stream_enabled   = true
    stream_view_type = "NEW_IMAGE"

    tables = {
      users = {
        attributes = [{ name = "id", type = "S" }]
        hash_key   = "id"
      }
      sessions = {
        attributes = [{ name = "id", type = "S" }]
        hash_key   = "id"
      }
    }
  }

  assert {
    condition = alltrue([
      for name, table in aws_dynamodb_table.this : table.stream_enabled
    ])
    error_message = "stream_enabled = true must still stream every table that sets no value of its own."
  }

  assert {
    condition = alltrue([
      for name, table in aws_dynamodb_table.this : table.stream_view_type == "NEW_IMAGE"
    ])
    error_message = "The module-wide view type must still reach every table that sets no value of its own."
  }
}

# Precedence, in both directions. A per-table value overrides the module-wide view type, and it also
# turns a stream on for its own table while the module-wide switch is off.
run "per_table_value_overrides_module_wide" {
  command = plan

  variables {
    stream_enabled   = true
    stream_view_type = "KEYS_ONLY"

    tables = {
      users = {
        attributes       = [{ name = "id", type = "S" }]
        hash_key         = "id"
        stream_view_type = "NEW_AND_OLD_IMAGES"
      }
      sessions = {
        attributes = [{ name = "id", type = "S" }]
        hash_key   = "id"
      }
    }
  }

  assert {
    condition     = aws_dynamodb_table.this["users"].stream_view_type == "NEW_AND_OLD_IMAGES"
    error_message = "A table's own stream_view_type must win over the module-wide value."
  }

  assert {
    condition     = aws_dynamodb_table.this["sessions"].stream_view_type == "KEYS_ONLY"
    error_message = "A table setting no value of its own must still take the module-wide view type."
  }
}

# A rejected view type is caught at plan time rather than by DynamoDB at apply time, which is the
# same guarantee the module's other validations give.
run "invalid_per_table_view_type_is_rejected" {
  command = plan

  variables {
    tables = {
      users = {
        attributes       = [{ name = "id", type = "S" }]
        hash_key         = "id"
        stream_view_type = "EVERYTHING"
      }
    }
  }

  expect_failures = [var.tables]
}
