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

run "one_secret_renders_a_bare_string_resource_and_the_two_read_actions" {
  command = plan

  override_resource {
    target          = aws_secretsmanager_secret.this
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    }
  }

  assert {
    condition     = jsondecode(output.read_policy_json).Statement[0].Resource == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    error_message = "A single covered secret must render as a bare JSON string rather than a one element list: that is the one-or-many convention IAM accepts and hand-written policies use, and it is what keeps a policy replacing a hand-written one byte-identical in state rather than merely equivalent."
  }

  assert {
    condition     = jsondecode(output.read_policy_json).Statement[0].Action == ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    error_message = "The default actions must be the pair an application needs to read a secret at cold start and check its metadata; dropping DescribeSecret breaks a client that calls it to resolve the current version stage."
  }

  assert {
    condition     = jsondecode(output.read_policy_json).Statement[0].Effect == "Allow"
    error_message = "The generated statement must be an Allow; a read policy that renders as anything else silently denies the application its own secrets."
  }

  assert {
    condition     = !contains(keys(jsondecode(output.read_policy_json).Statement[0]), "Sid")
    error_message = "policy_sid defaults to null and the statement must then render with no Sid at all, which is what a hand-written policy that never set one has in state; an invented Sid is a diff on adoption."
  }

  assert {
    condition     = jsondecode(output.read_policy_json).Version == "2012-10-17"
    error_message = "The document must carry the 2012-10-17 version, which is the only version IAM evaluates policy conditions and variables under."
  }

  assert {
    condition     = length(jsondecode(output.read_policy_json).Statement) == 1
    error_message = "The generated document must be exactly one statement; a consumer composing it into a larger policy through read_policy_statement relies on there being a single statement to merge."
  }
}

run "the_statement_output_is_the_same_statement_the_json_holds" {
  command = plan

  override_resource {
    target          = aws_secretsmanager_secret.this
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    }
  }

  assert {
    condition     = output.read_policy_statement.Resource == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    error_message = "read_policy_statement is what both consuming estates concat into their per-domain runtime policy, so it must carry the same resource the standalone document does; a statement that covers different secrets from the document is a grant nobody reviewed."
  }

  assert {
    condition     = output.read_policy_statement.Effect == "Allow"
    error_message = "The statement object must be usable as-is inside a hand-built jsonencode, which means it has to carry its own Effect rather than relying on the caller to add one."
  }

  assert {
    condition     = output.read_policy_statement == jsondecode(output.read_policy_json).Statement[0]
    error_message = "The object and the rendered document must not drift apart: a consumer that switches between the two outputs would otherwise change what the role is granted without changing anything in its own configuration."
  }

  assert {
    condition     = output.policy_resources == tolist(["arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"])
    error_message = "policy_resources is the escape hatch for a consumer writing the statement by hand, so it must always be the list form even when the rendered statement collapses to a bare string."
  }
}

run "several_secrets_render_a_sorted_list_of_resources" {
  command = plan

  variables {
    secrets = {
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
      session = {
        generate = true
      }
      "api-token" = {
        placeholder = "REPLACE_ME"
      }
    }
  }

  override_resource {
    target          = aws_secretsmanager_secret.this["app"]
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    }
  }

  override_resource {
    target          = aws_secretsmanager_secret.this["session"]
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/session-GhIjKl"
    }
  }

  override_resource {
    target          = aws_secretsmanager_secret.this["api-token"]
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/api-token-MnOpQr"
    }
  }

  assert {
    condition     = length(jsondecode(output.read_policy_json).Statement[0].Resource) == 3
    error_message = "With policy_secret_keys left null the policy must cover every secret the module manages; a secret created but left out of the grant is an application that reads it and gets AccessDenied at cold start."
  }

  assert {
    condition     = length(output.policy_resources) == 3
    error_message = "policy_resources must list one ARN per covered secret, which is what lets a consumer check the grant's breadth without parsing the rendered JSON."
  }

  assert {
    condition     = output.policy_resources == tolist(sort(output.policy_resources))
    error_message = "The resources must be sorted so the rendered policy is stable across reorderings of the secrets map; an unsorted list makes every unrelated map edit a policy diff."
  }

  assert {
    condition     = output.policy_resources[0] == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/api-token-MnOpQr"
    error_message = "Sorting must be on the ARN rather than on the map key, because the rendered document is what an operator diffs and it has to be reproducible from the ARNs alone."
  }
}

run "a_subset_of_keys_narrows_the_grant" {
  command = plan

  variables {
    secrets = {
      app = {
        json = { SECRET_KEY = "not-a-real-key" }
      }
      session = {
        generate = true
      }
    }

    policy_secret_keys = ["app"]
  }

  override_resource {
    target          = aws_secretsmanager_secret.this["app"]
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    }
  }

  override_resource {
    target          = aws_secretsmanager_secret.this["session"]
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/session-GhIjKl"
    }
  }

  assert {
    condition     = length(output.policy_resources) == 1
    error_message = "policy_secret_keys must narrow the grant to exactly the named secrets, which is how one role is given read access to some of the set and not all of it."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.this) == 2
    error_message = "Narrowing the policy must not narrow what the module creates: the secrets outside the grant still exist for a second role, or a second policy, to read."
  }

  assert {
    condition     = jsondecode(output.read_policy_json).Statement[0].Resource == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    error_message = "A one key subset must collapse to the bare string form and must name only the secret in the subset; the one-or-many rendering follows the number of covered resources rather than the number of secrets managed, and a resource from outside the subset is a grant the consumer did not ask for."
  }
}

run "a_custom_sid_and_a_single_action_render_the_way_iam_accepts_them" {
  command = plan

  variables {
    policy_sid     = "ReadAppSecrets"
    policy_actions = ["secretsmanager:GetSecretValue"]
  }

  override_resource {
    target          = aws_secretsmanager_secret.this
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    }
  }

  assert {
    condition     = jsondecode(output.read_policy_json).Statement[0].Sid == "ReadAppSecrets"
    error_message = "policy_sid must reach the statement when set: a Sid is how a reviewer identifies one statement among several in a composed policy, and both estates concat this statement into a larger document."
  }

  assert {
    condition     = jsondecode(output.read_policy_json).Statement[0].Action == "secretsmanager:GetSecretValue"
    error_message = "A single action must render as a bare string, matching the one-or-many convention, so a policy trimmed to GetSecretValue alone stays byte-identical to the hand-written one it replaces."
  }

  assert {
    condition     = output.read_policy_statement.Sid == "ReadAppSecrets"
    error_message = "The statement object must carry the Sid too, otherwise a consumer composing with it loses the label the rendered document would have had."
  }
}

run "a_sid_iam_would_reject_is_rejected" {
  command = plan

  variables {
    policy_sid = "Read-App-Secrets"
  }

  expect_failures = [var.policy_sid]
}

run "an_empty_action_list_is_rejected" {
  command = plan

  variables {
    policy_actions = []
  }

  expect_failures = [var.policy_actions]
}

run "an_action_outside_secrets_manager_is_rejected" {
  command = plan

  variables {
    policy_actions = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
  }

  expect_failures = [var.policy_actions]
}

run "the_arns_and_ids_outputs_are_keyed_by_the_consumers_own_short_names" {
  command = plan

  override_resource {
    target          = aws_secretsmanager_secret.this
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
      id  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    }
  }

  assert {
    condition     = output.arns["app"] == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    error_message = "arns is the output both estates hand to their functions as APP_SECRETS_ARN, so it must be the ARN of the secret this module created and keyed by the short name the consumer wrote."
  }

  assert {
    condition     = output.ids["app"] == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-staging/app-AbCdEf"
    error_message = "ids exists so a consumer that referenced .id on a hand-written resource does not have to change which attribute it reads; the provider returns the ARN there and the output must pass that through unchanged."
  }

  assert {
    condition     = keys(output.arns) == keys(output.names)
    error_message = "Every per-secret output must be keyed identically, because a consumer that looks a secret up in one map and then the other would otherwise fail on a key that exists in only one of them."
  }
}
