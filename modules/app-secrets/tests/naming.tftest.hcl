variables {
  name_prefix = "example-staging"

  secrets = {
    app = {
      description = "JSON map of runtime secrets read by the Lambda API at cold start"
      json = {
        SECRET_KEY = "not-a-real-key"
      }
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

run "a_secret_is_named_prefix_separator_key" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.this["app"].name == "example-staging/app"
    error_message = "The secret name must be name_prefix, name_separator and the map key in that order; this is the path-like convention both estates already have in state, and a different name creates a second secret while the application keeps reading the old one."
  }

  assert {
    condition     = output.names["app"] == "example-staging/app"
    error_message = "The names output is the secret-id an operator passes to aws secretsmanager put-secret-value, so it must be the full name rather than the short map key."
  }

  assert {
    condition     = keys(output.names) == ["app"]
    error_message = "Every output must stay keyed by the short map key the consumer wrote, because that is how a consumer reaches one secret out of several without knowing the naming rule."
  }
}

run "a_different_separator_reaches_the_name" {
  command = plan

  variables {
    name_separator = "_"
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].name == "example-staging_app"
    error_message = "name_separator must be what joins the prefix to the key, so an estate whose existing secrets use underscores can adopt the module without renaming anything."
  }
}

run "an_empty_prefix_makes_the_key_the_whole_name" {
  command = plan

  variables {
    name_prefix = ""
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].name == "app"
    error_message = "An empty name_prefix must leave the key as the entire name with no separator in front of it; a leading slash would be a different secret from the one an unprefixed estate already holds."
  }
}

run "an_explicit_name_overrides_the_prefix_entirely" {
  command = plan

  variables {
    secrets = {
      app = {
        name  = "carmodpicker/legacy-secret-key"
        value = "not-a-real-key"
      }
    }
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].name == "carmodpicker/legacy-secret-key"
    error_message = "A per-secret name must replace the whole derived name rather than being appended behind the prefix; it is the escape hatch that lets one module call adopt a secret whose historical name does not follow the estate's convention."
  }

  assert {
    condition     = output.names["app"] == "carmodpicker/legacy-secret-key"
    error_message = "The names output must follow the override, otherwise an operator running put-secret-value is pointed at a secret that does not exist."
  }
}

run "a_name_prefix_that_already_ends_in_a_separator_is_rejected" {
  command = plan

  variables {
    name_prefix = "example-staging/"
  }

  expect_failures = [var.name_prefix]
}

run "a_multi_character_separator_is_rejected" {
  command = plan

  variables {
    name_separator = "//"
  }

  expect_failures = [var.name_separator]
}

run "a_separator_secrets_manager_does_not_accept_is_rejected" {
  command = plan

  variables {
    name_separator = "#"
  }

  expect_failures = [var.name_separator]
}

run "a_secret_key_with_a_character_secrets_manager_rejects_is_rejected" {
  command = plan

  variables {
    secrets = {
      "app secrets" = {
        value = "not-a-real-key"
      }
    }
  }

  expect_failures = [var.secrets]
}

run "an_explicit_name_with_a_character_secrets_manager_rejects_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        name  = "example:staging:app"
        value = "not-a-real-key"
      }
    }
  }

  expect_failures = [var.secrets]
}

run "the_description_and_recovery_window_fall_back_to_the_module_defaults" {
  command = plan

  variables {
    description_default = "Managed by the platform app-secrets module"

    secrets = {
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
      session = {
        description = "Session signing key"
        generate    = true
      }
    }
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].description == "Managed by the platform app-secrets module"
    error_message = "A secret that sets no description of its own must take description_default, so an estate can label every secret it manages in one place."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["session"].description == "Session signing key"
    error_message = "A per-secret description must win over description_default; the fallback exists to fill gaps, not to overwrite a deliberate label."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].recovery_window_in_days == 0
    error_message = "recovery_window_in_days must default to 0: a secret whose name is reused soon after a destroy cannot be recreated while the old one is still scheduled for deletion, which turns a staging teardown into a week-long wait."
  }
}

run "a_per_secret_recovery_window_and_kms_key_override_the_module_defaults" {
  command = plan

  variables {
    recovery_window_in_days = 7
    kms_key_id              = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"

    tags = {
      Estate = "example"
    }

    secrets = {
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
      rebuildable = {
        generate                = true
        recovery_window_in_days = 0
        kms_key_id              = "arn:aws:kms:us-west-2:123456789012:key/99999999-8888-7777-6666-555555555555"
        tags = {
          Lifecycle = "rebuildable"
        }
      }
    }
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].recovery_window_in_days == 7
    error_message = "A secret that sets no window of its own must take the module default, which is how an estate keeps one recovery policy across every secret it manages."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["rebuildable"].recovery_window_in_days == 0
    error_message = "A per-secret recovery window must win over the module default, because a rebuildable secret wants immediate deletion while the shared ones stay recoverable."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].kms_key_id == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "The module-wide kms_key_id must reach a secret that names no key of its own, otherwise the secret silently falls back to the aws/secretsmanager key and an estate required to use its own key does not find out until an audit."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["rebuildable"].kms_key_id == "arn:aws:kms:us-west-2:123456789012:key/99999999-8888-7777-6666-555555555555"
    error_message = "A per-secret kms_key_id must win over the module default; a secret shared across accounts often needs a different key from the rest."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["app"].tags["Estate"] == "example"
    error_message = "Module-wide tags must reach every secret, which is what makes a single cost or ownership tag applicable to the whole set."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["rebuildable"].tags["Estate"] == "example"
    error_message = "Per-secret tags are merged over the module-wide ones rather than replacing them, so a secret that adds a tag must keep the shared ones too."
  }

  assert {
    condition     = aws_secretsmanager_secret.this["rebuildable"].tags["Lifecycle"] == "rebuildable"
    error_message = "A per-secret tag must land on that secret alone, which is how one secret in the set is marked out without touching the others."
  }

  assert {
    condition     = !contains(keys(aws_secretsmanager_secret.this["app"].tags), "Lifecycle")
    error_message = "A per-secret tag must not leak onto its siblings; tags here drive ownership and lifecycle reporting, and a leaked one misattributes every secret in the map."
  }
}

run "a_module_recovery_window_between_one_and_six_days_is_rejected" {
  command = plan

  variables {
    recovery_window_in_days = 3
  }

  expect_failures = [var.recovery_window_in_days]
}

run "a_module_recovery_window_above_thirty_days_is_rejected" {
  command = plan

  variables {
    recovery_window_in_days = 45
  }

  expect_failures = [var.recovery_window_in_days]
}

run "a_per_secret_recovery_window_secrets_manager_rejects_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        value                   = "not-a-real-key"
        recovery_window_in_days = 3
      }
    }
  }

  expect_failures = [var.secrets]
}
