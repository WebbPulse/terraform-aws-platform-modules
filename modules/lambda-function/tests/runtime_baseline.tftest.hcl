variables {
  function_name = "example-staging-api"

  runtime = "python3.13"
  handler = "app.lambda_handler.handler"

  code = {
    filename         = "placeholder.zip"
    source_code_hash = "3q2+7w=="
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

run "no_runtime_baseline_policy_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.runtime_baseline) == 0
    error_message = "The runtime baseline must be opt-in: an existing caller that sets none of its inputs must see no new inline policy in its plan."
  }

  assert {
    condition     = output.runtime_baseline_policy_json == null
    error_message = "The runtime_baseline_policy_json output must be null when no statement was asked for."
  }
}

run "secret_xray_and_kms_inputs_build_one_policy" {
  command = plan

  variables {
    enable_xray      = true
    app_secret_arns  = ["arn:aws:secretsmanager:us-west-2:123456789012:secret:example/staging/app-AbCdEf"]
    kms_key_arns     = ["arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"]
    kms_via_services = ["ssm.us-west-2.amazonaws.com"]
  }

  assert {
    condition     = length(aws_iam_role_policy.runtime_baseline) == 1 && aws_iam_role_policy.runtime_baseline[0].name == "runtime-baseline"
    error_message = "Any runtime baseline input must create exactly one inline policy named runtime-baseline."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.runtime_baseline[0].statement) == 3
    error_message = "X-Ray, the app secret and the KMS key must each add one statement, and nothing else may be granted."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.runtime_baseline[0].statement :
      statement.sid == "ReadTheAppSecret" && length(statement.actions) == 1 && contains(statement.actions, "secretsmanager:GetSecretValue") && length(statement.resources) == 1 && contains(statement.resources, "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/staging/app-AbCdEf")
    ])
    error_message = "The app secret statement must grant secretsmanager:GetSecretValue on exactly the given secret."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.runtime_baseline[0].statement :
      statement.sid == "WriteSpansToTheXRayOTLPEndpoint" && length(statement.actions) == 2 && contains(statement.actions, "xray:PutSpans") && contains(statement.actions, "xray:PutSpansForIndexing")
    ])
    error_message = "enable_xray must grant the two OTLP span actions."
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.runtime_baseline[0].statement :
      statement.sid == "DecryptWithTheGivenKeys" && contains(statement.actions, "kms:Decrypt") && anytrue([
        for condition in statement.condition :
        condition.test == "StringEquals" && condition.variable == "kms:ViaService" && contains(condition.values, "ssm.us-west-2.amazonaws.com")
      ])
    ])
    error_message = "kms_key_arns must grant kms:Decrypt, conditioned on kms:ViaService when kms_via_services is set."
  }
}

run "log_write_alone_creates_the_policy" {
  command = plan

  variables {
    enable_log_write = true
  }

  assert {
    condition     = length(aws_iam_role_policy.runtime_baseline) == 1
    error_message = "enable_log_write alone must create the runtime baseline policy."
  }
}

run "a_custom_policy_name_is_used" {
  command = plan

  variables {
    enable_xray                  = true
    runtime_baseline_policy_name = "example-staging-api-runtime"
  }

  assert {
    condition     = aws_iam_role_policy.runtime_baseline[0].name == "example-staging-api-runtime"
    error_message = "runtime_baseline_policy_name must name the inline policy, so a caller can adopt it over its own hand written policy name."
  }
}

run "a_kms_alias_arn_is_rejected" {
  command = plan

  variables {
    kms_key_arns = ["arn:aws:kms:us-west-2:123456789012:alias/aws/ssm"]
  }

  expect_failures = [var.kms_key_arns]
}

run "via_services_without_a_key_are_rejected" {
  command = plan

  variables {
    kms_via_services = ["ssm.us-west-2.amazonaws.com"]
  }

  expect_failures = [var.kms_via_services]
}

run "a_secret_name_in_place_of_an_arn_is_rejected" {
  command = plan

  variables {
    app_secret_arns = ["example/staging/app"]
  }

  expect_failures = [var.app_secret_arns]
}
