variables {
  name_prefix        = "example-staging"
  issuer             = "https://api.staging.example.com/api/auth"
  audience           = "example-staging-api"
  registrable_domain = "staging.example.com"

  attach_role_policies = false
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

run "no_mapping_and_no_stream_variables_by_default" {
  command = plan

  assert {
    condition     = length(aws_lambda_event_source_mapping.users_purge) == 0
    error_message = "The purge mapping must be opt-in: a consumer that never sets users_table_stream_arn has no users table stream for it to read."
  }

  assert {
    condition     = length(aws_iam_role_policy.users_stream) == 0
    error_message = "With no stream to read there is no stream to grant, so the inline policy must not be created."
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "AWS_LWA_PASS_THROUGH_PATH")
    error_message = "Pass through must stay off by default. Turning it on without a package that mounts the route makes the adapter post to a path that 404s."
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_EVENTS_PATH")
    error_message = "IDENTITY_EVENTS_PATH must be absent when no stream is wired."
  }

  assert {
    condition     = !contains(keys(local.identity_environment), "IDENTITY_USERS_KEY_ATTRIBUTE")
    error_message = "IDENTITY_USERS_KEY_ATTRIBUTE must be absent when no stream is wired."
  }

  assert {
    condition     = output.users_stream_policy_json == null
    error_message = "The stream policy output must be null when there is no stream ARN to name as a resource."
  }
}

run "a_stream_arn_creates_the_mapping_and_the_environment" {
  command = plan

  variables {
    users_table_stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-users/stream/2026-09-13T00:00:00.000"
    identity_function_name = "example-staging-identity"
  }

  assert {
    condition     = length(aws_lambda_event_source_mapping.users_purge) == 1
    error_message = "A users table stream ARN must create exactly one event source mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.users_purge[0].event_source_arn == var.users_table_stream_arn
    error_message = "The mapping must read the stream ARN it was given, unchanged."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.users_purge[0].function_name == "example-staging-identity"
    error_message = "The mapping must target the identity function, which is the one holding the identity table grants."
  }

  assert {
    condition     = contains(aws_lambda_event_source_mapping.users_purge[0].function_response_types, "ReportBatchItemFailures")
    error_message = "Without ReportBatchItemFailures a single failed record replays the whole batch, so already purged users are purged again and the shard stalls."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.users_purge[0].bisect_batch_on_function_error
    error_message = "Bisection is what stops one poison record from failing every record batched with it."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.users_purge[0].maximum_retry_attempts == 10
    error_message = "Retries must be bounded. Left unbounded a poison record blocks its shard until it expires at 24 hours."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.users_purge[0].batch_size == 10
    error_message = "The default batch size must reach the mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.users_purge[0].starting_position == "LATEST"
    error_message = "LATEST is the default so a first apply does not replay up to 24 hours of deletes somebody else already handled."
  }

  assert {
    condition     = local.identity_environment["AWS_LWA_PASS_THROUGH_PATH"] == "/events"
    error_message = "The adapter reads AWS_LWA_PASS_THROUGH_PATH to know where to post a non-HTTP invocation."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_EVENTS_PATH"] == "/events"
    error_message = "The application reads IDENTITY_EVENTS_PATH to know where to mount the purge route."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_USERS_KEY_ATTRIBUTE"] == "id"
    error_message = "The handler reads the deleted user id from dynamodb.Keys under this attribute name."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_ISSUER"] == var.issuer
    error_message = "Merging the stream variables must not disturb the variables that were already there."
  }
}

run "the_mapping_only_sees_removes" {
  command = plan

  variables {
    users_table_stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-users/stream/2026-09-13T00:00:00.000"
    identity_function_name = "example-staging-identity"
  }

  assert {
    condition = jsondecode(
      tolist(aws_lambda_event_source_mapping.users_purge[0].filter_criteria[0].filter)[0].pattern
    ).eventName == ["REMOVE"]
    error_message = "The filter must admit REMOVE alone. Without it every insert and every update of the users table invokes the identity function for nothing."
  }
}

run "the_adapter_path_and_the_route_path_cannot_drift" {
  command = plan

  variables {
    users_table_stream_arn   = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-users/stream/2026-09-13T00:00:00.000"
    identity_function_name   = "example-staging-identity"
    users_stream_events_path = "/internal/events"
    users_key_attribute      = "user_id"
  }

  assert {
    condition = (
      local.identity_environment["AWS_LWA_PASS_THROUGH_PATH"] ==
      local.identity_environment["IDENTITY_EVENTS_PATH"]
    )
    error_message = "One input feeds both variables, so the path the adapter posts to is the path the application listens on by construction."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_EVENTS_PATH"] == "/internal/events"
    error_message = "An overridden events path must reach both variables unchanged."
  }

  assert {
    condition     = local.identity_environment["IDENTITY_USERS_KEY_ATTRIBUTE"] == "user_id"
    error_message = "A users table keyed by something other than id must be able to say so."
  }
}

run "the_stream_grant_attaches_when_the_module_owns_the_policies" {
  command = plan

  variables {
    users_table_stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-users/stream/2026-09-13T00:00:00.000"
    identity_function_name = "example-staging-identity"
    identity_role_name     = "example-staging-identity"
    attach_role_policies   = true
  }

  assert {
    condition     = length(aws_iam_role_policy.users_stream) == 1
    error_message = "With a role name and attach_role_policies on, the stream read grant must be attached."
  }

  assert {
    condition = alltrue([
      for action in ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"] :
      contains(jsondecode(local.users_stream_policy_json).Statement[0].Action, action)
    ])
    error_message = "The mapping needs all four stream read actions; missing one leaves the mapping stuck in a retry loop with no records delivered."
  }

  assert {
    condition     = jsondecode(local.users_stream_policy_json).Statement[0].Resource == [var.users_table_stream_arn]
    error_message = "The grant must name the stream ARN alone rather than the table or a wildcard."
  }
}

run "a_stream_arn_without_a_function_is_rejected" {
  command = plan

  variables {
    users_table_stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-users/stream/2026-09-13T00:00:00.000"
  }

  expect_failures = [var.identity_function_name]
}

run "a_table_arn_in_place_of_a_stream_arn_is_rejected" {
  command = plan

  variables {
    users_table_stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-users"
    identity_function_name = "example-staging-identity"
  }

  expect_failures = [var.users_table_stream_arn]
}
