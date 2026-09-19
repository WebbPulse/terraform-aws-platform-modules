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

run "the_share_tokens_table_is_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_dynamodb_table.this) == 10
    error_message = "An existing consumer that says nothing must still plan exactly the ten identity tables, so taking this release is an empty plan."
  }

  assert {
    condition     = output.share_tokens_table_enabled == false
    error_message = "share_tokens_table_enabled must echo back false while the table is off."
  }

  assert {
    condition     = output.share_tokens_table_name == null
    error_message = "share_tokens_table_name must be null while the table is off."
  }

  assert {
    condition     = output.share_tokens_tenant_index_name == null
    error_message = "share_tokens_tenant_index_name must be null while the table is off."
  }

  assert {
    condition     = !contains(keys(local.table_names), "share-tokens")
    error_message = "No share-tokens key may reach table_names while the switch is off."
  }
}

run "turning_the_switch_on_adds_exactly_the_one_package_table" {
  command = plan

  variables {
    share_tokens_table_enabled = true
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 11
    error_message = "The share-tokens switch adds one table and is independent of the other two switches."
  }

  assert {
    condition     = aws_dynamodb_table.this["share-tokens"].name == "example-staging-share-tokens"
    error_message = "The logical key is the package constant SHARE_TOKENS_TABLE = \"share-tokens\", prefixed like every other identity table."
  }

  assert {
    condition     = local.all_tables["share-tokens"].hash_key == "token_hash"
    error_message = "SHARE_TOKEN_TABLE keys on token_hash: only the SHA-256 of a wps_ token is ever stored, so a leaked table authenticates as nobody."
  }

  assert {
    condition     = local.all_tables["share-tokens"].range_key == null
    error_message = "Resolving a presented token is one point read on token_hash, so the table carries no range key."
  }

  assert {
    condition     = local.all_tables["share-tokens"].ttl_attribute == "expires_at"
    error_message = "A share is a link a person hands out and forgets, so the row is reclaimed on IDENTITY_TTL_ATTRIBUTE, which is expires_at. This is where share-tokens differs from api-keys."
  }

  assert {
    condition     = length(local.all_tables["share-tokens"].attributes) == 3
    error_message = "DynamoDB wants an attribute definition for every key the table and its index use: token_hash, tenant_id and created_at."
  }

  assert {
    condition     = alltrue([for a in local.all_tables["share-tokens"].attributes : a.type == "S"])
    error_message = "Every share-tokens key attribute is a string: a hash, a tenant id and an ISO timestamp."
  }

  assert {
    condition     = one(local.all_tables["share-tokens"].global_secondary_indexes).name == "tenant_id-created_at-index"
    error_message = "list_for_tenant queries SHARE_TOKEN_TENANT_INDEX, which is tenant_id-created_at-index."
  }

  assert {
    condition     = one(local.all_tables["share-tokens"].global_secondary_indexes).range_key == "created_at"
    error_message = "The tenant index ranges on created_at so a settings page lists one tenant's shares newest last without sorting in the function."
  }

  assert {
    condition     = one(local.all_tables["share-tokens"].global_secondary_indexes).projection_type == "ALL"
    error_message = "The tenant listing renders the capability of each share, so a narrower projection would make every listed row a second read."
  }

  assert {
    condition     = output.share_tokens_table_enabled == true
    error_message = "share_tokens_table_enabled must echo back true so a consumer branching on the same switch reads it from one place."
  }

  assert {
    condition     = output.share_tokens_table_name == "example-staging-share-tokens"
    error_message = "The full table name must be exported, so a product passing it explicitly does not rebuild the prefix by hand."
  }

  assert {
    condition     = output.share_tokens_tenant_index_name == "tenant_id-created_at-index"
    error_message = "The tenant index name must be exported: the package reads it as a constant rather than from the environment, so a consumer renaming it has to pass it through."
  }
}

run "the_share_tokens_table_joins_the_role_grant" {
  command = plan

  variables {
    share_tokens_table_enabled = true
    attach_role_policies       = true
    identity_role_name         = "example-staging-identity"
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_tables) == 1
    error_message = "One table grant covers every table this module created, the share-tokens table included."
  }

  assert {
    condition     = length(local.table_arns_list) == 11
    error_message = "The identity role must reach the share-tokens table, or verifying a presented share token fails on an access denied."
  }

  assert {
    condition     = length(local.table_policy_resources) == 2 * length(local.table_arns_list)
    error_message = "The index wildcard must cover the tenant index, which listing and purging one tenant's shares queries."
  }
}

run "no_identity_environment_variable_follows_the_table" {
  command = plan

  variables {
    share_tokens_table_enabled = true
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_SHARE_TOKEN_TENANT_INDEX")
    error_message = "The package reads the tenant index as a constant, so adding an environment variable it ignores would read as configuration that does nothing."
  }
}

run "a_tenant_index_key_with_no_attribute_definition_is_refused" {
  command = plan

  variables {
    share_tokens_table_enabled = true

    share_tokens_table = {
      attributes = [
        { name = "token_hash", type = "S" },
        { name = "tenant_id", type = "S" },
      ]
      hash_key = "token_hash"
      global_secondary_indexes = [
        {
          name      = "tenant_id-created_at-index"
          hash_key  = "tenant_id"
          range_key = "created_at"
        },
      ]
      ttl_attribute = "expires_at"
    }
  }

  expect_failures = [var.share_tokens_table]
}

run "a_hash_key_that_is_not_an_attribute_is_refused" {
  command = plan

  variables {
    share_tokens_table_enabled = true

    share_tokens_table = {
      attributes = [{ name = "token_hash", type = "S" }]
      hash_key   = "tenant_id"
    }
  }

  expect_failures = [var.share_tokens_table]
}

run "all_three_switches_together_reach_fifteen_tables" {
  command = plan

  variables {
    oauth_server_enabled       = true
    api_keys_table_enabled     = true
    share_tokens_table_enabled = true
    attach_role_policies       = true
    identity_role_name         = "example-staging-identity"
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 15
    error_message = "Ten identity tables, three server tables, the api-keys table and the share-tokens table."
  }

  assert {
    condition     = length(local.table_arns_list) == 15
    error_message = "The share-tokens table must join the same role grant the other tables take."
  }

  assert {
    condition     = contains(keys(local.table_names), "share-tokens") && contains(keys(local.table_names), "api-keys") && contains(keys(local.table_names), "oauth-consents")
    error_message = "All three switches feed the one table map, so table_names answers for every table regardless of which switch created it."
  }

  assert {
    condition     = output.api_keys_tenant_index_name == output.share_tokens_tenant_index_name
    error_message = "Both credential tables list a tenant through the same tenant_id-created_at-index shape, and neither is the other's: they are separate tables because a share token authenticates as nobody while an API key acts as a person."
  }
}
