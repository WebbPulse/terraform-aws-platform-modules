provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_resource {
  target = aws_secretsmanager_secret.this
  values = {
    id  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
  }
}

override_resource {
  target = aws_secretsmanager_secret_version.this
}

override_resource {
  target = aws_secretsmanager_secret_version.json_generate
}

override_data {
  target = data.aws_secretsmanager_secrets.preserve
  values = {
    names = []
  }
}

variables {
  name_prefix = "example-staging"
}

run "before_a_json_secret" {
  command = apply

  variables {
    secrets = {
      app = {
        version = 2
        json    = { SECRET_KEY = "not-a-real-key" }
      }
    }
  }
}

run "dropping_json_and_turning_the_flag_on_keeps_the_address_and_counter" {
  command = plan

  plan_options {
    refresh = false
  }

  variables {
    secrets = {
      app = {
        version                 = 2
        json_preserve_unmanaged = true
      }
    }
  }

  assert {
    condition     = keys(aws_secretsmanager_secret_version.this) == ["app"] && length(aws_secretsmanager_secret_version.json_generate) == 0
    error_message = "The secret must stay on the plain version resource it was written by, or the migration destroys one version resource and creates another."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this["app"].secret_string_wo_version == 2
    error_message = "With version unchanged the write-only counter matches state, which is the only attribute the provider compares, so nothing is written and the keys already in AWS stay."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this["app"].secret_id == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    error_message = "secret_id forces a new version, so it must still point at the same secret."
  }
}

run "before_a_json_generate_secret" {
  command   = apply
  state_key = "json_generate"

  variables {
    secrets = {
      app = {
        version = 2
        json    = { SECRET_KEY = "not-a-real-key" }
        json_generate = {
          mfa_master_key = { format = "bytes32-base64" }
        }
      }
    }
  }
}

run "dropping_json_beside_json_generate_keeps_the_address_and_counter" {
  command   = plan
  state_key = "json_generate"

  variables {
    secrets = {
      app = {
        version                 = 2
        json_preserve_unmanaged = true
        json_generate = {
          mfa_master_key = { format = "bytes32-base64" }
        }
      }
    }
  }

  assert {
    condition     = keys(aws_secretsmanager_secret_version.json_generate) == ["app"] && length(aws_secretsmanager_secret_version.this) == 0
    error_message = "A json_generate secret must stay on the json_generate resource it was written by."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.json_generate["app"].secret_string_wo_version == 2
    error_message = "With version unchanged the write-only counter matches state, so the migration writes nothing."
  }
}
