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

run "the_server_tables_are_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_dynamodb_table.this) == 10
    error_message = "An existing consumer that says nothing must still plan exactly the ten identity tables, so taking this release is an empty plan."
  }

  assert {
    condition     = length(output.oauth_server_table_names) == 0
    error_message = "oauth_server_table_names must be empty while the server is off."
  }

  assert {
    condition     = output.api_keys_table_name == null
    error_message = "api_keys_table_name must be null while the api-keys table is off."
  }

  assert {
    condition     = output.consent_user_index_name == null
    error_message = "consent_user_index_name must be null while the server is off."
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_MCP_OAUTH_ENABLED") && !contains(keys(local.identity_environment), "IDENTITY_MCP_RESOURCE_URL")
    error_message = "No IDENTITY_MCP variable may reach the function while the server is off."
  }
}

run "turning_the_server_on_adds_exactly_the_three_package_tables" {
  command = plan

  variables {
    oauth_server_enabled = true
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 13
    error_message = "The flag adds the three tables in OAUTH_SERVER_TABLES and nothing else."
  }

  assert {
    condition     = aws_dynamodb_table.this["oauth-clients"].name == "example-staging-oauth-clients"
    error_message = "The logical key is the package constant OAUTH_CLIENTS_TABLE = \"oauth-clients\"."
  }

  assert {
    condition     = local.all_tables["oauth-clients"].hash_key == "client_id"
    error_message = "OAuthClientStore keys on client_id, so a different hash key fails at request time rather than at apply time."
  }

  assert {
    condition     = local.all_tables["oauth-clients"].ttl_attribute == "expires_at"
    error_message = "A dynamic registration is reclaimed on IDENTITY_TTL_ATTRIBUTE, which is expires_at."
  }

  assert {
    condition     = local.all_tables["authorization-codes"].hash_key == "code_hash"
    error_message = "Only the SHA-256 of a code is stored, and consume deletes by code_hash."
  }

  assert {
    condition     = local.all_tables["authorization-codes"].ttl_attribute == "expires_at"
    error_message = "An authorization code carries a TTL, re-checked in code because DynamoDB deletes on its own schedule."
  }

  assert {
    condition     = local.all_tables["oauth-consents"].hash_key == "consent_id"
    error_message = "ConsentStore keys on consent_id."
  }

  assert {
    condition     = local.all_tables["oauth-consents"].ttl_attribute == null
    error_message = "Consent never expires: a grant that vanished would send a user back through an authorization screen they cannot predict."
  }

  assert {
    condition     = one(local.all_tables["oauth-consents"].global_secondary_indexes).name == "user_id-index"
    error_message = "list_for_user queries CONSENT_USER_INDEX, which is user_id-index."
  }

  assert {
    condition     = output.consent_user_index_name == "user_id-index"
    error_message = "The consent index name must be exported, so a consumer passing user_index reads it from one place."
  }

  assert {
    condition     = length(output.oauth_server_table_names) == 3
    error_message = "oauth_server_table_names must carry the three server tables and nothing else."
  }
}

run "the_server_tables_join_the_role_grant" {
  command = plan

  variables {
    oauth_server_enabled = true
    attach_role_policies = true
    identity_role_name   = "example-staging-identity"
  }

  assert {
    condition     = length(aws_iam_role_policy.identity_tables) == 1
    error_message = "One table grant covers every table this module created, the server tables included."
  }

  assert {
    condition     = length(local.table_arns_list) == 13
    error_message = "The identity role must reach all thirteen tables, or every authorization fails on an access denied."
  }

  assert {
    condition     = length(local.table_policy_resources) == 2 * length(local.table_arns_list)
    error_message = "The index wildcard must cover the consent user index, which list_for_user queries."
  }
}

run "the_resource_url_is_what_mounts_the_server" {
  command = plan

  variables {
    oauth_server_enabled          = true
    oauth_server_mcp_resource_url = "https://api.staging.example.com/mcp"
  }

  assert {
    condition     = local.identity_environment["IDENTITY_MCP_OAUTH_ENABLED"] == "true"
    error_message = "A resource URL alongside the flag is the consumer saying the product is ready to pass oauth_server_stores."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_MCP_RESOURCE_URL"] == "https://api.staging.example.com/mcp"
    error_message = "The resource URL reaches the function byte for byte: it is the aud every MCP token carries."
  }
}

run "tables_without_a_resource_url_leave_the_package_flag_alone" {
  command = plan

  variables {
    oauth_server_enabled = true
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_MCP_OAUTH_ENABLED") && !contains(keys(local.identity_environment), "IDENTITY_MCP_RESOURCE_URL")
    error_message = "Creating the tables must not flip the package flag: the package refuses to boot with the flag on and no oauth_server_stores, so infrastructure that flipped it alone would turn a missing product argument into a dead function."
  }
}

run "a_resource_url_without_the_tables_is_refused" {
  command = plan

  variables {
    oauth_server_mcp_resource_url = "https://api.staging.example.com/mcp"
  }

  expect_failures = [var.oauth_server_mcp_resource_url]
}

run "a_plaintext_fragment_on_the_resource_url_is_refused" {
  command = plan

  variables {
    oauth_server_enabled          = true
    oauth_server_mcp_resource_url = "https://api.staging.example.com/mcp#frag"
  }

  expect_failures = [var.oauth_server_mcp_resource_url]
}

run "the_api_keys_table_carries_both_listing_indexes" {
  command = plan

  variables {
    api_keys_table_enabled = true
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 11
    error_message = "The api-keys switch adds one table and is independent of the server switch."
  }

  assert {
    condition     = local.all_tables["api-keys"].hash_key == "key_hash"
    error_message = "API_KEY_TABLE keys on key_hash: only the hash of a wpk_ key is ever stored."
  }

  assert {
    condition     = local.all_tables["api-keys"].ttl_attribute == null
    error_message = "An API key is revoked explicitly, never reclaimed on a TTL."
  }

  assert {
    condition     = output.api_keys_user_index_name == "user_id-created_at-index"
    error_message = "API_KEY_USER_INDEX lists one user's keys, newest last, for a settings page and for purge."
  }

  assert {
    condition     = output.api_keys_tenant_index_name == "tenant_id-created_at-index"
    error_message = "API_KEY_TENANT_INDEX lists one tenant's keys for a multi-tenant admin page; without it that listing is a scan."
  }

  assert {
    condition     = output.api_keys_table_name == "example-staging-api-keys"
    error_message = "The logical key is the package constant API_KEYS_TABLE = \"api-keys\"."
  }
}

run "both_switches_together_reach_fourteen_tables" {
  command = plan

  variables {
    oauth_server_enabled   = true
    api_keys_table_enabled = true
    attach_role_policies   = true
    identity_role_name     = "example-staging-identity"
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 14
    error_message = "Ten identity tables, three server tables and the api-keys table."
  }

  assert {
    condition     = length(local.table_arns_list) == 14
    error_message = "The api-keys table must join the same role grant the other tables take."
  }

  assert {
    condition     = contains(keys(local.table_names), "api-keys") && contains(keys(local.table_names), "oauth-consents")
    error_message = "Both switches feed the one table map, so table_names answers for every table regardless of which switch created it."
  }
}
