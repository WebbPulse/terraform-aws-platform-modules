variables {
  name_prefix        = "example-staging"
  issuer             = "https://api.staging.example.com/api/auth"
  audience           = "example-staging-api"
  registrable_domain = "staging.example.com"

  attach_role_policies = false
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

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

run "the_device_grant_tables_are_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_dynamodb_table.this) == 10
    error_message = "An existing consumer that says nothing must still plan exactly the ten identity tables, so taking this release is an empty plan."
  }

  assert {
    condition     = output.device_grant_enabled == false
    error_message = "device_grant_enabled must echo back false while the grant is off."
  }

  assert {
    condition     = output.device_grant_table_names == {}
    error_message = "device_grant_table_names must be empty while the grant is off."
  }

  assert {
    condition     = output.device_code_user_code_index_name == null && output.device_grant_user_index_name == null
    error_message = "Both index name outputs must be null while the grant is off: no index exists to name when no table does."
  }

  assert {
    condition     = !contains(keys(local.table_names), "device-codes") && !contains(keys(local.table_names), "device-grants")
    error_message = "No device grant key may reach table_names while the switch is off."
  }
}

run "turning_the_switch_on_adds_exactly_the_two_package_tables" {
  command = plan

  variables {
    device_grant_enabled = true
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 12
    error_message = "The device grant switch adds two tables and is independent of the other switches."
  }

  assert {
    condition     = aws_dynamodb_table.this["device-codes"].name == "example-staging-device-codes"
    error_message = "The logical key is DEVICE_CODES_TABLE = \"device-codes\", prefixed by the <prefix>-<logical> rule dynamo_device_grant_stores resolves."
  }

  assert {
    condition     = aws_dynamodb_table.this["device-grants"].name == "example-staging-device-grants"
    error_message = "The logical key is DEVICE_GRANTS_TABLE = \"device-grants\", prefixed by the <prefix>-<logical> rule dynamo_device_grant_stores resolves."
  }

  assert {
    condition     = local.all_tables["device-codes"].hash_key == "device_code_hash" && local.all_tables["device-codes"].range_key == null
    error_message = "DynamoDeviceCodeStore reads and writes by device_code_hash alone."
  }

  assert {
    condition     = local.all_tables["device-grants"].hash_key == "grant_id" && local.all_tables["device-grants"].range_key == null
    error_message = "DynamoDeviceGrantStore reads and writes by grant_id alone."
  }

  assert {
    condition     = local.all_tables["device-codes"].ttl_attribute == "expires_at" && local.all_tables["device-grants"].ttl_attribute == "expires_at"
    error_message = "Both tables are reclaimed on IDENTITY_TTL_ATTRIBUTE, which is expires_at."
  }

  assert {
    condition = [
      for g in local.all_tables["device-codes"].global_secondary_indexes :
      [g.name, g.hash_key, coalesce(g.range_key, "none"), g.projection_type]
    ] == [["user_code_hash-index", "user_code_hash", "none", "KEYS_ONLY"]]
    error_message = "device-codes carries DEVICE_CODE_USER_CODE_INDEX on user_code_hash, KEYS_ONLY, since the store reads the row back consistently from the table."
  }

  assert {
    condition = [
      for g in local.all_tables["device-grants"].global_secondary_indexes :
      [g.name, g.hash_key, coalesce(g.range_key, "none"), g.projection_type]
    ] == [["user_id-index", "user_id", "none", "ALL"]]
    error_message = "device-grants carries DEVICE_GRANT_USER_INDEX on user_id projecting every attribute, since listing a user's sessions builds records straight from the index."
  }

  assert {
    condition = alltrue(flatten([
      for key in ["device-codes", "device-grants"] : [
        for a in local.all_tables[key].attributes : a.type == "S"
      ]
    ]))
    error_message = "Every device grant key attribute is a string."
  }

  assert {
    condition = output.device_grant_table_names == {
      "device-codes"  = "example-staging-device-codes"
      "device-grants" = "example-staging-device-grants"
    }
    error_message = "device_grant_table_names must name both tables under the prefix."
  }

  assert {
    condition     = output.device_code_user_code_index_name == "user_code_hash-index"
    error_message = "The user code index name must be exported."
  }

  assert {
    condition     = output.device_grant_user_index_name == "user_id-index"
    error_message = "The user index name must be exported."
  }

  assert {
    condition     = output.device_grant_enabled == true
    error_message = "device_grant_enabled must echo back true."
  }
}

run "the_device_grant_tables_join_the_role_grant" {
  command = plan

  variables {
    device_grant_enabled = true
    attach_role_policies = true
    identity_role_name   = "example-staging-identity"
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_tables) == 1
    error_message = "One table grant covers every table this module created, the device grant tables included."
  }

  assert {
    condition     = length(local.table_arns_list) == 12
    error_message = "The identity role must reach both device grant tables, or the device flow fails on an access denied."
  }

  assert {
    condition     = length(local.table_policy_resources) == 2 * length(local.table_arns_list)
    error_message = "The index wildcard must cover both device grant indexes."
  }

  assert {
    condition     = contains(var.table_policy_actions, "dynamodb:DeleteItem")
    error_message = "The identity function consumes device codes and purges a deleted user's rows with DeleteItem, so the default grant must carry it."
  }
}

run "no_identity_environment_variable_follows_the_tables" {
  command = plan

  variables {
    device_grant_enabled = true
  }

  assert {
    condition     = length([for k in keys(local.identity_environment) : k if startswith(k, "IDENTITY_DEVICE")]) == 0
    error_message = "The package also needs device_clients and device_scopes_supported before it boots with the grant on, so the product sets the flag itself and the module emits nothing."
  }
}

run "additional_table_grants_may_name_the_device_tables_when_on" {
  command = plan

  variables {
    device_grant_enabled = true
    additional_table_grants = {
      purge = {
        role_name = "example-staging-purge"
        tables    = ["device-grants"]
        actions   = ["dynamodb:DeleteItem", "dynamodb:Query"]
      }
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.additional_table_grants) == 1
    error_message = "A second role may be granted the device-grants table once the switch is on."
  }
}

run "additional_table_grants_may_not_name_the_device_tables_when_off" {
  command = plan

  variables {
    additional_table_grants = {
      purge = {
        role_name = "example-staging-purge"
        tables    = ["device-grants"]
      }
    }
  }

  expect_failures = [var.additional_table_grants]
}

run "an_index_key_with_no_attribute_definition_is_refused" {
  command = plan

  variables {
    device_grant_enabled = true

    device_grant_tables = {
      "device-codes" = {
        attributes = [{ name = "device_code_hash", type = "S" }]
        hash_key   = "device_code_hash"
        global_secondary_indexes = [
          {
            name            = "user_code_hash-index"
            hash_key        = "user_code_hash"
            projection_type = "KEYS_ONLY"
          },
        ]
        ttl_attribute = "expires_at"
      }
    }
  }

  expect_failures = [var.device_grant_tables]
}

run "all_four_switches_together_reach_seventeen_tables" {
  command = plan

  variables {
    oauth_server_enabled       = true
    api_keys_table_enabled     = true
    share_tokens_table_enabled = true
    device_grant_enabled       = true
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 17
    error_message = "Ten identity tables, three server tables, api-keys, share-tokens and the two device grant tables."
  }
}
