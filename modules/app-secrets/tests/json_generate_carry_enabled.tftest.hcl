variables {
  name_prefix = "example-staging"

  secrets = {
    app = {
      json_generate = {
        mfa_master_key = { format = "bytes32-base64", keep = true }
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

run "the_default_reads_a_kept_entry_back_as_before" {
  command = plan

  assert {
    condition     = local.json_generate_carry_keys == toset(["app"])
    error_message = "Leaving json_generate_carry_enabled at its default must keep the historic behaviour: a kept entry reads the secret's current version, which is where the value it carries forward comes from."
  }

  assert {
    condition     = local.json_generate_carry["app"]["mfa_master_key"]
    error_message = "A kept entry must still be marked as carried forward by default, otherwise an estate whose secret already holds a live key would rotate it on the next write of the blob."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.json_generate) == 1
    error_message = "The blob must still be written by the json_generate resource, since the carry switch decides where a kept value comes from and never whether the secret gets a version."
  }
}

run "carry_disabled_declares_no_read_and_still_writes_the_version" {
  command = plan

  variables {
    json_generate_carry_enabled = false
  }

  assert {
    condition     = local.json_generate_carry_keys == toset([])
    error_message = "json_generate_carry_enabled false must leave the ephemeral read's for_each empty, so the read is not declared at all; that read is what fails on a fresh account, where the same apply creates the secret and then cannot find a version to read."
  }

  assert {
    condition     = !local.json_generate_carry["app"]["mfa_master_key"]
    error_message = "With the carry switched off a kept entry must be minted fresh, exactly as keep = false does, because there is no stored value to carry forward on the first apply."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.json_generate) == 1
    error_message = "The version must still be written when the carry is off: the first apply is the one that creates the secret's first version, and skipping the write would leave the application reading an empty secret."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.json_generate["app"].secret_string_wo_version == 1
    error_message = "The write-only counter must be untouched by the carry switch, because only version drives a rewrite and flipping the switch back to true must not republish the blob on its own."
  }
}

run "carry_disabled_is_a_no_op_when_nothing_is_kept" {
  command = plan

  variables {
    json_generate_carry_enabled = false

    secrets = {
      app = {
        json_generate = {
          mfa_master_key = { format = "bytes32-base64" }
        }
      }
    }
  }

  assert {
    condition     = local.json_generate_carry_keys == toset([])
    error_message = "A secret with no kept entry never read itself back to begin with, so switching the carry off must change nothing about which secrets are read."
  }

  assert {
    condition     = length(aws_secretsmanager_secret_version.json_generate) == 1
    error_message = "A secret whose entries are all minted fresh must get its version written whatever the carry switch says, since the switch only ever decides where a kept value comes from."
  }
}
