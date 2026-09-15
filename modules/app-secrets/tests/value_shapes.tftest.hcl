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
    condition     = jsondecode(aws_secretsmanager_secret_version.this["app"].secret_string)["SECRET_KEY"] == "not-a-real-key"
    error_message = "Every entry of the json map must reach the stored object under its own key, because the application reads these by name and a dropped key is a missing configuration value that only surfaces at the first cold start."
  }

  assert {
    condition     = length(keys(jsondecode(aws_secretsmanager_secret_version.this["app"].secret_string))) == 3
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
    condition     = !contains(keys(jsondecode(aws_secretsmanager_secret_version.this["app"].secret_string)), "SENTRY_DSN")
    error_message = "A null entry must be dropped entirely: it is how a consumer wires an optional variable straight into the map, and a literal null in the blob would be parsed as a configured value of none rather than as absent."
  }

  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.this["app"].secret_string)["FEATURE_FLAGS"] == ""
    error_message = "An empty string entry must be kept, because an application that distinguishes set to empty from absent needs the key present, and that distinction is the only reason null and empty are treated differently here."
  }

  assert {
    condition     = length(keys(jsondecode(aws_secretsmanager_secret_version.this["app"].secret_string))) == 2
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
    condition     = aws_secretsmanager_secret_version.this["secret-key"].secret_string == "not-a-real-key"
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
    condition     = aws_secretsmanager_secret_version.this["out-of-band"].secret_string == ""
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
    condition     = aws_secretsmanager_secret_version.placeholder["api-token"].secret_string == "REPLACE_ME"
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

run "a_generated_secret_gets_a_random_password_with_the_providers_own_defaults" {
  command = plan

  variables {
    secrets = {
      session = {
        generate = true
      }
    }
  }

  assert {
    condition     = length(random_password.this) == 1
    error_message = "generate must create exactly one random_password per generated secret; the value never leaves state and the module never reads it back, which is the whole point of the shape."
  }

  assert {
    condition     = random_password.this["session"].length == 32
    error_message = "generate_length must default to 32, which is the provider's own default, so an existing random_password resource can be moved into the module without the generator's arguments changing and the value being regenerated."
  }

  assert {
    condition     = random_password.this["session"].special
    error_message = "generate_special must default to true to match the provider's default; flipping it would regenerate the value of every secret an adopting consumer moved in."
  }

  assert {
    condition     = random_password.this["session"].min_special == 0
    error_message = "The generate_min_ floors must all default to zero, again matching the provider, because a non-zero floor changes the generated value and therefore rotates a live secret on adoption."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 1
    error_message = "A generated secret must get a Terraform-managed version holding the generated result; without it the random_password exists in state and the secret an application reads stays empty."
  }
}

run "the_generator_arguments_reach_random_password" {
  command = plan

  variables {
    secrets = {
      session = {
        generate                  = true
        generate_length           = 64
        generate_special          = true
        generate_override_special = "!#$%"
        generate_min_special      = 4
        generate_min_numeric      = 4
        generate_min_upper        = 4
        generate_min_lower        = 4
      }
    }
  }

  assert {
    condition     = random_password.this["session"].length == 64
    error_message = "generate_length must reach the generator, because it is the only control a consumer has over how much entropy the secret carries."
  }

  assert {
    condition     = random_password.this["session"].override_special == "!#$%"
    error_message = "generate_override_special must reach the generator verbatim; it is how a consumer keeps a secret inside the character set some downstream system accepts, and a dropped value produces a secret that system rejects."
  }

  assert {
    condition     = random_password.this["session"].min_numeric == 4
    error_message = "Each generate_min floor must reach the generator on its own, since a floor silently dropped produces a secret that fails a complexity policy the consumer believed it was enforcing."
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
    condition     = length(random_password.this) == 0
    error_message = "With no secrets there is nothing to generate; a stray random_password would sit in state with no secret to write it to."
  }

  assert {
    condition     = length(output.arns) == 0
    error_message = "The arns output must be an empty map rather than failing, because a consumer that looks up a key conditionally still evaluates the output."
  }
}

run "json_generate_bytes_adds_generated_keys_to_the_same_object" {
  command = plan

  variables {
    secrets = {
      app = {
        json = {
          SECRET_KEY = "not-a-real-key"
        }
        json_generate_bytes = {
          mfa_master_key = 32
        }
      }
    }
  }

  assert {
    condition     = length(random_bytes.json) == 1
    error_message = "A json_generate_bytes entry must mint exactly one random_bytes resource, because the value is generated here rather than passed in and a missing resource would store the key absent."
  }

  assert {
    condition     = random_bytes.json["app.mfa_master_key"].length == 32
    error_message = "The generated value must carry the byte length the consumer asked for; a shorter master key would silently weaken every seed derived from it."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.this) == 1
    error_message = "A json secret carrying generated entries is still one blob Terraform owns, so it must land in the managed version resource the application reads at cold start."
  }
}

run "json_generate_bytes_requires_json" {
  command = plan

  variables {
    secrets = {
      app = {
        json_generate_bytes = {
          mfa_master_key = 32
        }
      }
    }
  }

  expect_failures = [var.secrets]
}

run "json_generate_bytes_refuses_a_key_json_already_sets" {
  command = plan

  variables {
    secrets = {
      app = {
        json = {
          mfa_master_key = "not-a-real-key"
        }
        json_generate_bytes = {
          mfa_master_key = 32
        }
      }
    }
  }

  expect_failures = [var.secrets]
}
