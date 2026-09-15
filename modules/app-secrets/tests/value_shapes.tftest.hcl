variables {
  name_prefix = "example-staging"

  secrets = {
    app = {
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

run "a_json_secret_is_stored_as_one_blob_terraform_owns" {
  command = plan

  variables {
    secrets = {
      app = {
        json = {
          SECRET_KEY                 = "not-a-real-key"
          SENTRY_DSN                 = "https://example@sentry.invalid/1"
          OAUTH_GOOGLE_CLIENT_SECRET = "not-a-real-client-secret"
        }
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 1
    error_message = "A json secret is a value Terraform owns, so it must land in the managed version resource; this is the single blob the application reads at cold start through APP_SECRETS_ARN and both estates depend on it existing."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.placeholder) == 0
    error_message = "A json secret must not use the placeholder resource: that resource ignores changes to the value, so a rotated secret would be written once and never updated again."
  }

  assert {
    condition     = jsondecode(local.static_version_strings["app"])["SECRET_KEY"] == "not-a-real-key"
    error_message = "Every entry of the json map must reach the stored object under its own key, because the application reads these by name and a dropped key is a missing configuration value that only surfaces at the first cold start."
  }

  assert {
    condition     = length(keys(jsondecode(local.static_version_strings["app"]))) == 3
    error_message = "The stored object must hold exactly the entries the consumer passed, so a consumer can predict what the application parses without reading the value back out of AWS."
  }
}

run "a_json_entry_that_is_null_is_dropped_and_an_empty_string_is_kept" {
  command = plan

  variables {
    secrets = {
      app = {
        json = {
          SECRET_KEY    = "not-a-real-key"
          SENTRY_DSN    = null
          FEATURE_FLAGS = ""
        }
      }
    }
  }

  assert {
    condition     = !contains(keys(jsondecode(local.static_version_strings["app"])), "SENTRY_DSN")
    error_message = "A null entry must be dropped entirely: it is how a consumer wires an optional variable straight into the map, and a literal null in the blob would be parsed as a configured value of none rather than as absent."
  }

  assert {
    condition     = jsondecode(local.static_version_strings["app"])["FEATURE_FLAGS"] == ""
    error_message = "An empty string entry must be kept, because an application that distinguishes set to empty from absent needs the key present, and that distinction is the only reason null and empty are treated differently here."
  }

  assert {
    condition     = length(keys(jsondecode(local.static_version_strings["app"]))) == 2
    error_message = "Exactly the non-null entries must survive, so the count of keys in the blob is predictable from the module call."
  }
}

run "a_value_secret_is_stored_verbatim" {
  command = plan

  variables {
    secrets = {
      "secret-key" = {
        value = "not-a-real-key"
      }
    }
  }

  assert {
    condition     = local.static_version_strings["secret-key"] == "not-a-real-key"
    error_message = "A value secret must be stored exactly as passed, with no encoding or wrapping, because the application reads the raw string rather than parsing it."
  }

  assert {
    condition     = keys(aws_secretsmanager_secret_version.this) == keys(aws_secretsmanager_secret.this)
    error_message = "The version must be written against the secret this module created, which means one version keyed exactly like the secret it belongs to; a key that appears in one map and not the other leaves a managed secret empty while the application reads nothing."
  }
}

run "an_empty_value_is_the_same_as_no_value_at_all" {
  command = plan

  variables {
    secrets = {
      optional = {
        value = ""
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret.this) == 1
    error_message = "The secret itself must still be created for an empty value, because the application's IAM grant has to be stable whether or not the optional variable is set yet."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 0
    error_message = "Secrets Manager has no empty version, so an empty string must count as no value; writing one would fail at apply and block every other secret in the same plan."
  }
}

run "a_secret_with_no_source_gets_no_version_by_default" {
  command = plan

  variables {
    secrets = {
      "out-of-band" = {
        description = "Populated entirely by an operator"
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret.this) == 1
    error_message = "A secret populated out of band must still exist, because that is what makes the application's read grant and its environment wiring stable before any value has been put."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 0
    error_message = "With no source and create_empty_version off, Terraform must manage no version at all; the operator's first put-secret-value creates version 1, and a Terraform-owned empty version would be a version the next put has to fight."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.placeholder) == 0
    error_message = "A secret with no source must not get a placeholder version either; the two shapes are different and only an explicit placeholder value asks for a seeded, then ignored, version."
  }

  assert {
    condition     = length(output.version_ids) == 0
    error_message = "version_ids must be empty when Terraform manages no version, so a consumer using it purely to force ordering does not build a dependency on a version that does not exist."
  }
}

run "create_empty_version_gives_a_sourceless_secret_a_version_resource" {
  command = plan

  variables {
    create_empty_version = true

    secrets = {
      "out-of-band" = {}
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 1
    error_message = "create_empty_version must produce the version resource for a secret with no source, which is what a consumer that wants the resource to exist regardless of whether its optional variable is set asks for."
  }

  assert {
    condition     = local.static_version_strings["out-of-band"] == ""
    error_message = "The version created this way must hold an empty string, because there is no value to store and any invented placeholder would be read by the application as real configuration."
  }
}

run "a_placeholder_secret_is_seeded_in_its_own_resource" {
  command = plan

  variables {
    secrets = {
      "api-token" = {
        placeholder = "REPLACE_ME"
      }
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.placeholder) == 1
    error_message = "A placeholder secret must land in the placeholder resource, which is the only one carrying ignore_changes on the value; that is what lets an operator set the real secret out of band without Terraform planning it back on the next run."
  }

  assert {
    condition     = local.static_version_strings["api-token"] == "REPLACE_ME"
    error_message = "The literal must be seeded once so the secret has a version from the start, which keeps a cold start from failing with ResourceNotFoundException before the operator has acted."
  }

  assert {
    condition     = !contains(keys(aws_secretsmanager_secret_version.this), "api-token")
    error_message = "A placeholder secret must not also appear in the managed version resource: two version resources on one secret would fight, each overwriting the other on alternate applies."
  }

  assert {
    condition     = contains(keys(aws_secretsmanager_secret_version.this), "app")
    error_message = "Splitting placeholders into their own resource must not pull the ordinary managed secrets out with them; a json secret alongside a placeholder still needs Terraform to own its value."
  }
}

run "a_generated_secret_gets_a_version_written_from_an_ephemeral_password" {
  command = plan

  variables {
    secrets = {
      session = {
        generate = true
      }
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 1
    error_message = "A generated secret must get a Terraform-managed version; the value is written straight from the ephemeral generator, and without the version resource the secret an application reads stays empty."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this["session"].secret_string_wo_version == 1
    error_message = "A generated secret's write-only counter must default to 1. The generator produces a fresh value on every run, so this counter is the only thing that decides whether Secrets Manager is written, and a counter that moved on its own would rotate the secret on an unrelated apply."
  }

  assert {
    condition     = contains(keys(local.generated_keys), "session") || contains(local.generated_keys, "session")
    error_message = "generate must mark the key as generated so the module writes it from the ephemeral password rather than from the static string map."
  }

  assert {
    condition     = !contains(keys(local.static_version_strings), "session") || local.static_version_strings["session"] == ""
    error_message = "A generated secret must carry no static string: its value exists only for the duration of the run, and a static entry holding it would be the state leak this shape exists to avoid."
  }
}

run "the_generated_key_set_follows_the_generate_flag" {
  command = plan

  variables {
    secrets = {
      session = {
        generate        = true
        generate_length = 64
      }
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
    }
  }

  assert {
    condition     = length(local.generated_keys) == 1
    error_message = "Only a secret setting generate may be written from the ephemeral generator; pulling a json secret in would replace a value the consumer supplied with a random one."
  }

  assert {
    condition     = contains(local.generated_keys, "session")
    error_message = "The secret that sets generate must be the one in the generated set, otherwise the module writes the wrong secret from the generator."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 2
    error_message = "A generated secret and a json secret must each get their own managed version resource, since both are values Terraform writes."
  }
}

run "a_secret_that_sets_two_sources_at_once_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        value = "not-a-real-key"
        json  = { SECRET_KEY = "not-a-real-key" }
      }
    }
  }

  expect_failures = [var.secrets]
}

run "a_generated_secret_that_also_passes_a_placeholder_is_rejected" {
  command = plan

  variables {
    secrets = {
      session = {
        generate    = true
        placeholder = "REPLACE_ME"
      }
    }
  }

  expect_failures = [var.secrets]
}

run "an_empty_json_map_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        json = {}
      }
    }
  }

  expect_failures = [var.secrets]
}

run "a_generate_length_below_eight_is_rejected" {
  command = plan

  variables {
    secrets = {
      session = {
        generate        = true
        generate_length = 4
      }
    }
  }

  expect_failures = [var.secrets]
}

run "a_generate_length_above_five_hundred_and_twelve_is_rejected" {
  command = plan

  variables {
    secrets = {
      session = {
        generate        = true
        generate_length = 600
      }
    }
  }

  expect_failures = [var.secrets]
}

run "generate_minimums_that_exceed_the_length_are_rejected" {
  command = plan

  variables {
    secrets = {
      session = {
        generate             = true
        generate_length      = 8
        generate_min_special = 4
        generate_min_numeric = 4
        generate_min_upper   = 4
        generate_min_lower   = 4
      }
    }
  }

  expect_failures = [var.secrets]
}

run "an_empty_secrets_map_creates_nothing" {
  command = plan

  variables {
    secrets = {}
  }

  assert {
    condition     = length(aws_secretsmanager_secret.this) == 0
    error_message = "An empty secrets map must create no secrets, so a consumer can wire the module in behind a flag and turn it on later without a plan that half creates the set."
  }

  assert {
    condition     = length(local.generated_keys) == 0
    error_message = "With no secrets there is nothing to generate; a stray generated key would ask the module to write a secret that does not exist."
  }

  assert {
    condition     = length(output.arns) == 0
    error_message = "The arns output must be an empty map rather than failing, because a consumer that looks up a key conditionally still evaluates the output."
  }
}

run "the_write_only_counter_defaults_to_one_and_is_passed_through" {
  command = plan

  variables {
    secrets = {
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
      rotated = {
        value   = "not-a-real-key"
        version = 4
      }
    }
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this["app"].secret_string_wo_version == 1
    error_message = "A secret that names no version must sit at 1, so an estate adopting the write-only module writes each value once and then stays quiet on every later run."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this["rotated"].secret_string_wo_version == 4
    error_message = "An explicit version must reach the resource verbatim: it is the only signal the provider has that the value changed, because a write-only value is never in state to compare against."
  }
}

run "a_version_below_one_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        value   = "not-a-real-key"
        version = 0
      }
    }
  }

  expect_failures = [var.secrets]
}

run "a_fractional_version_is_rejected" {
  command = plan

  variables {
    secrets = {
      app = {
        value   = "not-a-real-key"
        version = 1.5
      }
    }
  }

  expect_failures = [var.secrets]
}
