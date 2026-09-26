variables {
  name_prefix = "example-staging"

  secrets = {
    app = {
      json_preserve_unmanaged = true
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

run "the_first_write_of_a_new_secret_falls_back_to_the_declared_keys" {
  command = plan

  override_data {
    target = data.aws_secretsmanager_secrets.preserve["app"]
    values = { names = [] }
  }

  assert {
    condition     = local.preserve_keys == toset(["app"])
    error_message = "json_preserve_unmanaged must mark the secret as preserving its live keys."
  }

  assert {
    condition     = local.current_read_keys == toset([])
    error_message = "A secret that does not exist yet has no version to read, so the ephemeral read must not be declared; declaring it fails the first apply."
  }

  assert {
    condition     = length(data.aws_secretsmanager_secret_versions.preserve) == 0
    error_message = "Listing versions of a secret that does not exist fails, so the versions lookup must only run for a secret the name lookup found."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 1
    error_message = "A preserving secret with no json and no json_generate must still get a version, so the migration from a json secret keeps the same resource address."
  }

  assert {
    condition     = local.static_version_strings["app"] == "{}"
    error_message = "With nothing declared and nothing live, the first write must be an empty JSON object the application can parse."
  }
}

run "an_empty_json_map_is_accepted_with_the_flag" {
  command = plan

  variables {
    secrets = {
      app = {
        json                    = {}
        json_preserve_unmanaged = true
      }
    }
  }

  override_data {
    target = data.aws_secretsmanager_secrets.preserve["app"]
    values = { names = [] }
  }

  assert {
    condition     = local.managed_keys == toset(["app"])
    error_message = "An empty json map is valid once the flag is on, and the secret must be written by the plain version resource."
  }
}

run "an_existing_secret_with_a_current_version_is_read_back" {
  command = plan

  variables {
    secrets = {
      app = {
        json                    = { SENTRY_DSN = "https://example@sentry.invalid/1" }
        json_preserve_unmanaged = true
        version                 = 3
      }
    }
  }

  override_data {
    target = data.aws_secretsmanager_secrets.preserve["app"]
    values = { names = ["example-staging/app"] }
  }

  override_data {
    target = data.aws_secretsmanager_secret_versions.preserve["app"]
    values = {
      versions = [
        { version_id = "v2", version_stages = ["AWSPREVIOUS"], created_time = "", last_accessed_date = "" },
        { version_id = "v3", version_stages = ["AWSCURRENT"], created_time = "", last_accessed_date = "" },
      ]
    }
  }

  assert {
    condition     = local.current_read_keys == toset(["app"])
    error_message = "A preserving secret that already holds a current version must read it, because the live keys are the base every write starts from."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this["app"].secret_string_wo_version == 3
    error_message = "The write-only counter must still come from version alone."
  }
}

run "a_secret_with_no_current_version_is_not_read" {
  command = plan

  override_data {
    target = data.aws_secretsmanager_secrets.preserve["app"]
    values = { names = ["example-staging/app"] }
  }

  override_data {
    target = data.aws_secretsmanager_secret_versions.preserve["app"]
    values = { versions = [] }
  }

  assert {
    condition     = local.current_read_keys == toset([])
    error_message = "A secret created empty has no AWSCURRENT version, and reading it fails, so the module must fall back to the declared keys."
  }
}

run "a_prefix_match_from_list_secrets_is_not_mistaken_for_the_secret" {
  command = plan

  override_data {
    target = data.aws_secretsmanager_secrets.preserve["app"]
    values = { names = ["example-staging/app-legacy"] }
  }

  assert {
    condition     = local.preserve_existing_keys == toset([])
    error_message = "The ListSecrets name filter matches prefixes, so only an exact name match may count as the secret existing."
  }
}

run "the_flag_combines_with_json_generate_on_a_new_secret" {
  command = plan

  variables {
    secrets = {
      app = {
        json_preserve_unmanaged = true
        json_generate = {
          mfa_master_key = { format = "bytes32-base64", keep = true }
        }
      }
    }
  }

  override_data {
    target = data.aws_secretsmanager_secrets.preserve["app"]
    values = { names = [] }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.json_generate) == 1 && length(aws_secretsmanager_secret_version.this) == 0
    error_message = "A preserving secret with json_generate must stay on the json_generate resource, the address it has today."
  }

  assert {
    condition     = !local.json_generate_carry["app"]["mfa_master_key"]
    error_message = "On a preserving secret, a kept entry is carried only when a current version exists, so a fresh account mints it rather than failing on the read."
  }

  assert {
    condition     = local.current_read_keys == toset([])
    error_message = "No read may be declared for a secret that does not exist yet, even with json_generate_carry_enabled left true."
  }
}

run "the_flag_combines_with_json_generate_on_a_live_secret" {
  command = plan

  variables {
    json_generate_carry_enabled = false

    secrets = {
      app = {
        json_preserve_unmanaged = true
        json_generate = {
          mfa_master_key = { format = "bytes32-base64", keep = true }
          rotated_key    = { format = "password" }
        }
      }
    }
  }

  override_data {
    target = data.aws_secretsmanager_secrets.preserve["app"]
    values = { names = ["example-staging/app"] }
  }

  override_data {
    target = data.aws_secretsmanager_secret_versions.preserve["app"]
    values = {
      versions = [{ version_id = "v1", version_stages = ["AWSCURRENT"], created_time = "", last_accessed_date = "" }]
    }
  }

  assert {
    condition     = local.json_generate_carry["app"]["mfa_master_key"]
    error_message = "On a preserving secret the version lookup decides the carry, so a kept entry is carried whenever a current version exists."
  }

  assert {
    condition     = !local.json_generate_carry["app"]["rotated_key"]
    error_message = "An entry without keep must still be minted fresh on a write, laid over the live value of the same key."
  }

  assert {
    condition     = local.current_read_keys == toset(["app"])
    error_message = "One read must serve both the preserved base and the kept entries."
  }
}

run "a_secret_without_the_flag_does_no_lookups" {
  command = plan

  variables {
    secrets = {
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
    }
  }

  assert {
    condition     = length(data.aws_secretsmanager_secrets.preserve) == 0 && local.current_read_keys == toset([])
    error_message = "Existing consumers must see no new data sources and no new reads."
  }
}

run "the_flag_with_a_plain_value_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        value                   = "not-a-real-key"
        json_preserve_unmanaged = true
      }
    }
  }

  expect_failures = [var.secrets]
}

run "the_flag_with_a_placeholder_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        placeholder             = "REPLACE_ME"
        json_preserve_unmanaged = true
      }
    }
  }

  expect_failures = [var.secrets]
}

run "the_flag_with_generate_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        generate                = true
        json_preserve_unmanaged = true
      }
    }
  }

  expect_failures = [var.secrets]
}
