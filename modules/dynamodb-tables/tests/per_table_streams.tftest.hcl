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
}

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
