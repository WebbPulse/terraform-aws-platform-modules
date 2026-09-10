# The table key schemas, which are the identity package's contract rather than this module's taste.
#
# webbpulse.identity.storage and webbpulse.identity.lockout write these exact attribute names. A
# table whose hash key does not match what the store writes applies cleanly and then fails at
# request time, on the login path, in production. So these runs pin the schemas against the
# package's constants: if someone edits the default tables map, one of these fails before the plan
# ever reaches an account.

variables {
  name_prefix        = "example-staging"
  issuer             = "https://api.staging.example.com/api/auth"
  audience           = "example-staging-api"
  registrable_domain = "staging.example.com"
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

# The KMS key policy names the account root, which means a real GetCallerIdentity call. A mocked
# provider has no credentials to make one, so the account id and partition are supplied here. They
# are the only values the module reads from either data source.
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

run "the_four_identity_tables_exist_with_the_package_names" {
  command = plan

  assert {
    condition     = length(aws_dynamodb_table.this) == 4
    error_message = "The default must create the four tables the identity flows read and write."
  }

  # webbpulse.dynamodb.table_name builds "<prefix>-<logical>", so the module's names and the names
  # the application resolves at runtime have to be the same string.
  assert {
    condition     = aws_dynamodb_table.this["credentials"].name == "example-staging-credentials"
    error_message = "Table names must be <name_prefix>-<logical key>, which is what webbpulse.dynamodb.table_name resolves to."
  }

  assert {
    condition     = aws_dynamodb_table.this["refresh-tokens"].name == "example-staging-refresh-tokens"
    error_message = "The logical key is hyphenated because the package constant is REFRESH_TOKENS_TABLE = \"refresh-tokens\"."
  }

  assert {
    condition     = aws_dynamodb_table.this["identity-tokens"].name == "example-staging-identity-tokens"
    error_message = "The logical key is hyphenated because the package constant is IDENTITY_TOKENS_TABLE = \"identity-tokens\"."
  }

  assert {
    condition     = aws_dynamodb_table.this["login-attempts"].name == "example-staging-login-attempts"
    error_message = "The logical key is hyphenated because the package constant is LOGIN_ATTEMPTS_TABLE = \"login-attempts\"."
  }
}

run "credentials_is_keyed_for_one_row_per_credential_type_and_never_expires" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["credentials"].hash_key == "user_id"
    error_message = "storage.py reads credentials by user_id."
  }

  assert {
    condition     = aws_dynamodb_table.this["credentials"].range_key == "credential_type"
    error_message = "The range key is credential_type, so one user holds a password row and passkey rows side by side."
  }

  # This is the argument section 4.1 of the standard makes for per-entity tables. TTL is
  # table-level, so a credentials table that had one would be a single bug away from deleting the
  # only way an account can be signed in to.
  assert {
    condition     = var.tables["credentials"].ttl_attribute == null
    error_message = "The credentials table must never have a TTL attribute: an expiring password hash deletes the account's only way back in."
  }
}

run "refresh_tokens_verifies_on_the_primary_key_and_revokes_through_the_index" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["refresh-tokens"].hash_key == "token_hash"
    error_message = "Verification must be a GetItem on token_hash, with no index on the hot path."
  }

  assert {
    condition     = aws_dynamodb_table.this["refresh-tokens"].range_key == null
    error_message = "token_hash alone identifies a row; a range key would force a Query where a GetItem belongs."
  }

  # The index name is load-bearing: storage.py names it as a literal in the Query call.
  assert {
    condition     = one(aws_dynamodb_table.this["refresh-tokens"].global_secondary_index).name == "family_id-generation-index"
    error_message = "The GSI name must be exactly family_id-generation-index: REFRESH_FAMILY_INDEX in storage.py names it as a literal and a rename breaks family revocation."
  }

  assert {
    condition     = one(aws_dynamodb_table.this["refresh-tokens"].global_secondary_index).hash_key == "family_id"
    error_message = "Revoking a family queries by family_id."
  }

  assert {
    condition     = one(aws_dynamodb_table.this["refresh-tokens"].global_secondary_index).range_key == "generation"
    error_message = "generation orders a family, which is how reuse of an old generation is detected."
  }

  assert {
    condition     = var.tables["refresh-tokens"].ttl_attribute == "expires_at"
    error_message = "Refresh tokens must expire on expires_at, which is the attribute the store writes."
  }
}

run "the_short_lived_tables_expire_on_the_attribute_the_package_writes" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["identity-tokens"].hash_key == "token_hash"
    error_message = "Verification and reset tokens are looked up by their hash."
  }

  assert {
    condition     = var.tables["identity-tokens"].ttl_attribute == "expires_at"
    error_message = "identity-tokens must expire on expires_at."
  }

  assert {
    condition     = aws_dynamodb_table.this["login-attempts"].hash_key == "identity_key"
    error_message = "lockout.py counts attempts under identity_key, which is email#<lower> or ip#<addr>."
  }

  # The range key is the timestamp, so recording an attempt appends rather than overwrites. A table
  # keyed only by identity_key would keep one row and count nothing.
  assert {
    condition     = aws_dynamodb_table.this["login-attempts"].range_key == "attempted_at"
    error_message = "attempted_at must be the range key so each attempt is its own row inside the lookback window."
  }

  assert {
    condition     = var.tables["login-attempts"].ttl_attribute == "expires_at"
    error_message = "login-attempts must expire on expires_at; the rows are only useful inside the lookback window."
  }
}

run "backups_default_to_on_except_where_there_is_nothing_to_restore" {
  command = plan

  assert {
    condition     = coalesce(var.tables["credentials"].point_in_time_recovery, var.point_in_time_recovery)
    error_message = "Credentials hold user state that cannot be regenerated, so continuous backups default on."
  }

  assert {
    condition     = coalesce(var.tables["refresh-tokens"].point_in_time_recovery, var.point_in_time_recovery)
    error_message = "Refresh tokens default to continuous backups with the rest."
  }

  # Not the environment switch talking: every row is a failure counter inside a lookback window, so
  # there is no point in time worth restoring to.
  assert {
    condition     = var.tables["login-attempts"].point_in_time_recovery == false
    error_message = "login-attempts overrides the module default to false: the rows are counters, not state."
  }

  assert {
    condition     = alltrue([for t in aws_dynamodb_table.this : t.billing_mode == "PAY_PER_REQUEST"])
    error_message = "Identity access patterns are point lookups whose volume tracks sign-ins, which is what on-demand is for."
  }

  assert {
    condition     = alltrue([for t in aws_dynamodb_table.this : !t.deletion_protection_enabled])
    error_message = "Deletion protection defaults off so a staging teardown is not a manual console step; a production consumer passes true."
  }
}

# A consumer that already creates its tables through its own dynamodb-tables call wants only the
# key and the authorizer from this module.
run "tables_can_be_turned_off_entirely" {
  command = plan

  variables {
    tables             = {}
    identity_role_name = "example-staging-identity"
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 0
    error_message = "An empty tables map must create no tables."
  }

  # No tables means no resources for a table policy to name, and an IAM policy with an empty
  # resource list is invalid rather than merely useless.
  assert {
    condition     = length(aws_iam_role_policy.identity_tables) == 0
    error_message = "With no tables there must be no table policy: a policy statement with an empty resource list is rejected by IAM."
  }
}

# The key schema validations exist so a typo fails at plan rather than at request time.
run "a_hash_key_with_no_attribute_definition_is_rejected" {
  command = plan

  variables {
    tables = {
      typo = {
        attributes = [{ name = "user_id", type = "S" }]
        hash_key   = "userid"
      }
    }
  }

  expect_failures = [var.tables]
}

run "an_index_key_with_no_attribute_definition_is_rejected" {
  command = plan

  variables {
    tables = {
      "refresh-tokens" = {
        attributes = [{ name = "token_hash", type = "S" }]
        hash_key   = "token_hash"
        global_secondary_indexes = [
          {
            name     = "family_id-generation-index"
            hash_key = "family_id"
          },
        ]
      }
    }
  }

  expect_failures = [var.tables]
}
