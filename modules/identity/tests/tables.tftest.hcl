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

run "the_ten_identity_tables_exist_with_the_package_names" {
  command = plan

  assert {
    condition     = length(aws_dynamodb_table.this) == 10
    error_message = "The default must create the ten tables the identity flows read and write: the four from M1, totp-factors and recovery-codes from M4, passkeys and webauthn-challenges from M5, and oauth-states and oauth-links from M6."
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

  assert {
    condition     = aws_dynamodb_table.this["totp-factors"].name == "example-staging-totp-factors"
    error_message = "The logical key is hyphenated because the package constant is TOTP_FACTORS_TABLE = \"totp-factors\"."
  }

  assert {
    condition     = aws_dynamodb_table.this["recovery-codes"].name == "example-staging-recovery-codes"
    error_message = "The logical key is hyphenated because the package constant is RECOVERY_CODES_TABLE = \"recovery-codes\"."
  }

  assert {
    condition     = aws_dynamodb_table.this["passkeys"].name == "example-staging-passkeys"
    error_message = "The logical key is the package constant PASSKEYS_TABLE = \"passkeys\"."
  }

  assert {
    condition     = aws_dynamodb_table.this["webauthn-challenges"].name == "example-staging-webauthn-challenges"
    error_message = "The logical key is hyphenated because the package constant is WEBAUTHN_CHALLENGES_TABLE = \"webauthn-challenges\"."
  }

  assert {
    condition     = aws_dynamodb_table.this["oauth-states"].name == "example-staging-oauth-states"
    error_message = "The logical key is hyphenated because the package constant is OAUTH_STATES_TABLE = \"oauth-states\"."
  }

  assert {
    condition     = aws_dynamodb_table.this["oauth-links"].name == "example-staging-oauth-links"
    error_message = "The logical key is hyphenated because the package constant is OAUTH_LINKS_TABLE = \"oauth-links\"."
  }
}

# M4. One factor per user, so user_id alone is the key: re-enrolling replaces the seed rather than
# adding a row, which is what keeps the login challenge's factor list a derivation rather than a
# query.
run "totp_factors_is_one_row_per_user_and_never_expires" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["totp-factors"].hash_key == "user_id"
    error_message = "storage.py reads a TOTP factor by user_id."
  }

  assert {
    condition     = aws_dynamodb_table.this["totp-factors"].range_key == null
    error_message = "One factor per user means user_id alone identifies the row; a range key would allow two factors and make the login challenge a query."
  }

  assert {
    condition     = length(var.tables["totp-factors"].global_secondary_indexes) == 0
    error_message = "Every access to a factor is by user_id on the primary key, so an index would cost a write on every enrolment to serve nothing."
  }

  # The sharpest case of section 4.1's rule. An expiring refresh token costs a user one extra
  # login; a TOTP factor that vanishes early costs them the account, and if MFA is required for
  # their role they cannot get in at all.
  assert {
    condition     = var.tables["totp-factors"].ttl_attribute == null
    error_message = "totp-factors must never carry a TTL attribute: a second factor that expires on its own silently drops the account to one, with no error anybody sees."
  }
}

# M4. The range key is the hash of the code, so spending one is a point write on the primary key
# with no index and no scan, and reading a whole set is one Query on the partition.
run "recovery_codes_are_keyed_for_a_point_spend_and_never_expire" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["recovery-codes"].hash_key == "user_id"
    error_message = "A user's whole set of codes must live in one partition so listing them is a single Query."
  }

  assert {
    condition     = aws_dynamodb_table.this["recovery-codes"].range_key == "code_hash"
    error_message = "The range key must be code_hash: consuming a code is a conditional write on the primary key, with no index and no scan."
  }

  assert {
    condition     = length(var.tables["recovery-codes"].global_secondary_indexes) == 0
    error_message = "Both operations, listing a set and spending one code, are served by the primary key alone."
  }

  assert {
    condition     = var.tables["recovery-codes"].ttl_attribute == null
    error_message = "recovery-codes must never carry a TTL attribute: a code that expires on its own is a user locked out of an account they hold the paper for."
  }

  # Only the SHA-256 of each code is stored, so both key attributes are strings.
  assert {
    condition     = length([for a in var.tables["recovery-codes"].attributes : a if a.type != "S"]) == 0
    error_message = "Both key attributes are strings: user_id is an id and code_hash is a hex digest."
  }
}

# M5. The base table is keyed for the management page, which reads its own writes: listing a user's
# credentials has to be a consistent Query on the primary key, and a GSI read cannot be consistent.
# The index serves the opposite lookup, credential id to owner, on the login path.
run "passkeys_lists_consistently_on_the_base_table_and_logs_in_through_the_index" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["passkeys"].hash_key == "user_id"
    error_message = "A user's whole set of credentials must live in one partition so listing them is a single consistent Query rather than a GSI read."
  }

  assert {
    condition     = aws_dynamodb_table.this["passkeys"].range_key == "credential_id"
    error_message = "The range key must be credential_id: renaming or deleting one passkey is a point write on the primary key."
  }

  # The index name is load-bearing: PASSKEY_CREDENTIAL_INDEX in storage.py names it as a literal in
  # the Query call, so a rename here is a failed lookup on the login path rather than a plan diff.
  assert {
    condition     = one(aws_dynamodb_table.this["passkeys"].global_secondary_index).name == "credential_id-index"
    error_message = "The GSI name must be exactly credential_id-index: PASSKEY_CREDENTIAL_INDEX names it as a literal and a rename breaks passkey sign-in."
  }

  assert {
    condition     = one(aws_dynamodb_table.this["passkeys"].global_secondary_index).hash_key == "credential_id"
    error_message = "The login lookup goes from the credential id the authenticator returned to its owner, so credential_id is the index hash key."
  }

  # Asserted on the input rather than on the resource: the provider renders an unset index range key
  # as the empty string rather than as null, so a null check against the attribute never holds.
  assert {
    condition     = one(var.tables["passkeys"].global_secondary_indexes).range_key == null
    error_message = "A credential id identifies one credential, so the index needs no range key."
  }

  # ALL rather than KEYS_ONLY: the login path needs the stored public key and the sign count off
  # the index read, and a KEYS_ONLY projection would turn every sign-in into a second GetItem.
  assert {
    condition     = one(aws_dynamodb_table.this["passkeys"].global_secondary_index).projection_type == "ALL"
    error_message = "The index must project ALL: the login lookup reads the public key and the sign count from it, and KEYS_ONLY would cost a second read on every sign-in."
  }

  # The same rule as totp-factors and recovery-codes, and for the same reason with more force under
  # passkeys_passwordless: a credential that vanishes on a schedule is a factor silently removed
  # from an account, and it may have been the only one.
  assert {
    condition     = var.tables["passkeys"].ttl_attribute == null
    error_message = "passkeys must never carry a TTL attribute: a passkey that expires on its own removes a factor, possibly the only factor, from an account with nothing to say so."
  }

  assert {
    condition     = length([for a in var.tables["passkeys"].attributes : a if a.type != "S"]) == 0
    error_message = "Both key attributes are strings: user_id is an id and credential_id is the base64url credential id."
  }
}

# M5. The one identity table whose rows are meant to disappear. A challenge is a row rather than a
# token because unreplayability is a claim about state, and a signed token verifies exactly as well
# the second time as the first.
run "webauthn_challenges_is_a_single_use_row_that_expires_on_expires_at" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["webauthn-challenges"].hash_key == "challenge_id"
    error_message = "A challenge is looked up and deleted by its own id, so challenge_id is the whole key."
  }

  assert {
    condition     = aws_dynamodb_table.this["webauthn-challenges"].range_key == null
    error_message = "challenge_id alone identifies a challenge; a range key would force a Query where a GetItem and a conditional delete belong."
  }

  assert {
    condition     = length(var.tables["webauthn-challenges"].global_secondary_indexes) == 0
    error_message = "Every access to a challenge is by challenge_id on the primary key, so an index would cost a write per ceremony to serve nothing."
  }

  # TTL is storage reclamation, never access control: the deadline is checked in code on every read
  # regardless, so a row DynamoDB has not got round to is still refused. Pointing this at another
  # attribute breaks nothing visibly and grows the table forever, which is why it is contract.
  assert {
    condition     = var.tables["webauthn-challenges"].ttl_attribute == "expires_at"
    error_message = "webauthn-challenges must expire on expires_at, which is the attribute the store writes."
  }
}

# M6. The OAuth analogue of webauthn-challenges, and a row for the same reason: a state binds a
# callback to the request that started it, which is a claim about state a signed value cannot make.
run "oauth_states_is_a_single_use_row_that_expires_on_expires_at" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["oauth-states"].hash_key == "state"
    error_message = "A state is spent by a conditional DeleteItem on its own value, so state is the whole key."
  }

  assert {
    condition     = aws_dynamodb_table.this["oauth-states"].range_key == null
    error_message = "state alone identifies a row; a range key would force a Query where a conditional delete belongs."
  }

  assert {
    condition     = length(var.tables["oauth-states"].global_secondary_indexes) == 0
    error_message = "Every access to a state is by its own value on the primary key, so an index would cost a write per sign-in attempt to serve nothing."
  }

  # Storage reclamation, not access control: the ten minute deadline is re-checked in code on every
  # read, so a row DynamoDB has not got round to is refused rather than accepted.
  assert {
    condition     = var.tables["oauth-states"].ttl_attribute == "expires_at"
    error_message = "oauth-states must expire on expires_at, which is the attribute the store writes."
  }
}

# M6. Keyed on the provider identity so uniqueness is the primary key: attaching a provider is one
# conditional put on attribute_not_exists(provider_subject) rather than a read-then-write.
run "oauth_links_is_keyed_on_the_provider_identity_and_lists_through_the_index" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.this["oauth-links"].hash_key == "provider_subject"
    error_message = "The hash key must be provider_subject (\"<provider>#<subject>\"): that is what makes the uniqueness constraint the primary key and a race resolve to one winner."
  }

  assert {
    condition     = aws_dynamodb_table.this["oauth-links"].range_key == null
    error_message = "One provider identity is one row, so provider_subject alone identifies it."
  }

  # The index name is load-bearing: OAUTH_LINK_USER_INDEX in storage.py names it as a literal in the
  # Query call, so a rename here breaks listing a user's links and the last-method count in unlink.
  assert {
    condition     = one(aws_dynamodb_table.this["oauth-links"].global_secondary_index).name == "user_id-index"
    error_message = "The GSI name must be exactly user_id-index: OAUTH_LINK_USER_INDEX names it as a literal."
  }

  assert {
    condition     = one(aws_dynamodb_table.this["oauth-links"].global_secondary_index).hash_key == "user_id"
    error_message = "Listing a user's links and counting their remaining sign-in methods both query by user_id."
  }

  # Asserted on the input rather than on the resource: the provider renders an unset index range key
  # as the empty string rather than as null, so a null check against the attribute never holds.
  assert {
    condition     = one(var.tables["oauth-links"].global_secondary_indexes).range_key == null
    error_message = "A user's links need no ordering, so the index needs no range key."
  }

  assert {
    condition     = one(aws_dynamodb_table.this["oauth-links"].global_secondary_index).projection_type == "ALL"
    error_message = "The index must project ALL: listing a user's links reads the whole record from it, and KEYS_ONLY would cost a read per link."
  }

  # A link is a sign-in method and may be the only one. The package refuses an unlink that would
  # remove the last way in, and a TTL would do exactly that with nobody to refuse it.
  assert {
    condition     = var.tables["oauth-links"].ttl_attribute == null
    error_message = "oauth-links must never carry a TTL attribute: a link that expires on its own can be the last sign-in method an account has."
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

# Two tables now carry an index and both are Queried by name on a request path, so the grant has to
# reach index ARNs. DynamoDB treats an index as its own resource: dynamodb:Query on table/<name>
# alone is an AccessDenied that names the table, on a request that read an index.
run "the_table_grant_reaches_the_index_on_every_indexed_table" {
  command = plan

  variables {
    identity_role_name = "example-staging-identity"
  }

  # The refresh token family revocation, the passkey login lookup and the OAuth link listing.
  assert {
    condition     = length([for k, t in var.tables : k if length(t.global_secondary_indexes) > 0]) == 3
    error_message = "Exactly three default tables carry an index: refresh-tokens for family revocation, passkeys for the login lookup and oauth-links for listing a user's links."
  }

  # ARNs are unknown until apply, so what is checkable at plan is the shape: one table entry and one
  # index entry per table. A table-only policy would be half this length.
  assert {
    condition     = length(local.table_policy_resources) == 2 * length(local.table_arns_list)
    error_message = "Every table must contribute both its own ARN and an index wildcard, or a Query against a named index is denied."
  }

  assert {
    condition     = contains(var.table_policy_actions, "dynamodb:Query")
    error_message = "dynamodb:Query is what both index reads make, so the grant is useless without it."
  }
}

# The index entries are the table ARNs with /index/* appended, which is the resource form DynamoDB
# matches a Query on a global secondary index against. A real ARN is not known until apply, so this
# run overrides the tables to make the strings knowable and then checks the shape the policy builds.
run "an_index_resource_is_the_table_arn_with_index_appended" {
  command = plan

  variables {
    identity_role_name = "example-staging-identity"
    tables = {
      passkeys = {
        attributes = [
          { name = "user_id", type = "S" },
          { name = "credential_id", type = "S" },
        ]
        hash_key  = "user_id"
        range_key = "credential_id"
        global_secondary_indexes = [
          {
            name     = "credential_id-index"
            hash_key = "credential_id"
          },
        ]
      }
    }
  }

  override_resource {
    target          = aws_dynamodb_table.this
    override_during = plan
    values = {
      arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-passkeys"
    }
  }

  assert {
    condition = local.table_policy_resources == [
      "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-passkeys",
      "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-passkeys/index/*",
    ]
    error_message = "The grant must name the table ARN and that ARN with /index/* appended: DynamoDB authorises an index read against the index resource, not the table's."
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
