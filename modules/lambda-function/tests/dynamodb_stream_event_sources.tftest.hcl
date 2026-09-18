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

run "no_mapping_and_no_pass_through_by_default" {
  command = plan

  assert {
    condition     = length(aws_lambda_event_source_mapping.dynamodb_stream) == 0
    error_message = "A DynamoDB stream event source must be opt-in: a consumer that names no stream has nothing for this function to read, and an existing consumer must see no plan change."
  }

  assert {
    condition     = length(aws_iam_role_policy.dynamodb_stream_event_source) == 0
    error_message = "With no stream to read there is no stream to grant, so the inline policy must not be created."
  }

  assert {
    condition     = !contains(keys(local.environment_variables), "AWS_LWA_PASS_THROUGH_PATH")
    error_message = "Pass through must stay off by default. Turning it on without a package that mounts the route makes the adapter post to a path that 404s, and the mapping then retries the batch until the record expires."
  }

  assert {
    condition     = output.events_path == null
    error_message = "The events_path output must be null when no mapping exists, so a consumer branching on it does not advertise a route the function does not serve."
  }
}

run "a_stream_creates_the_mapping_the_grant_and_the_pass_through" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
      }
    }
  }

  assert {
    condition     = length(aws_lambda_event_source_mapping.dynamodb_stream) == 1
    error_message = "One stream entry must create exactly one event source mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].event_source_arn == "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
    error_message = "The mapping must read the stream ARN it was given, unchanged."
  }

  assert {
    condition     = contains(aws_lambda_event_source_mapping.dynamodb_stream["issues"].function_response_types, "ReportBatchItemFailures")
    error_message = "Without ReportBatchItemFailures a single failed record replays the whole batch, and a stream shard blocks on that batch until it succeeds or expires."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].starting_position == "LATEST"
    error_message = "The default starting position must be LATEST, so wiring a stream to an existing table does not replay up to 24 hours of history on the first apply."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].batch_size == 100
    error_message = "The default batch size must reach the mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].maximum_batching_window_in_seconds == 0
    error_message = "The default batching window must be 0, so a record reaches the function as soon as it lands rather than waiting for a batch to fill."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].bisect_batch_on_function_error
    error_message = "Bisecting on error is what stops one poisoned record failing every other record in its batch forever."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].enabled
    error_message = "A mapping must read by default; a disabled mapping is a stream that silently ages out."
  }

  assert {
    condition     = length(aws_lambda_event_source_mapping.dynamodb_stream["issues"].destination_config) == 0
    error_message = "With no on_failure_destination_arn the destination_config block must be left out entirely rather than written with a null."
  }

  assert {
    condition     = length(aws_iam_role_policy.dynamodb_stream_event_source) == 1
    error_message = "With attach_role_policies on, the stream read grant must be attached: Lambda checks it during the CreateEventSourceMapping call."
  }

  assert {
    condition = alltrue([
      for action in ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"] :
      contains(jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement[0].Action, action)
    ])
    error_message = "A stream reader needs all four actions; missing one leaves the mapping unable to iterate the shards and the failure is an access denied rather than an empty stream."
  }

  assert {
    condition     = length(jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement[0].Action) == 4
    error_message = "The grant must be exactly the four actions a stream reader calls. dynamodb:* on a table also grants item writes, which a consumer has no reason to hold."
  }

  assert {
    condition     = jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement[0].Resource == ["arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"]
    error_message = "The grant must name the stream ARN alone rather than a wildcard."
  }

  assert {
    condition     = length(jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement) == 1
    error_message = "With no on failure destination there is nothing to write to, so the policy must carry the stream statement alone."
  }

  assert {
    condition     = local.environment_variables["AWS_LWA_PASS_THROUGH_PATH"] == "/events"
    error_message = "The adapter reads AWS_LWA_PASS_THROUGH_PATH to know where to post a non-HTTP invocation, which is how a stream batch reaches the FastAPI app."
  }

  assert {
    condition     = local.environment_variables["APP_EVENTS_PATH"] == "/events"
    error_message = "The application reads APP_EVENTS_PATH to know where to mount the event route."
  }

  assert {
    condition     = output.events_path == "/events"
    error_message = "A wired stream must advertise the events path on the output the same way a wired queue does."
  }
}

run "explicit_settings_and_a_filter_reach_the_mapping" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn                         = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
        batch_size                         = 10
        starting_position                  = "TRIM_HORIZON"
        maximum_batching_window_in_seconds = 5
        bisect_batch_on_function_error     = false
        maximum_retry_attempts             = 3

        filter_patterns = [
          "{\"eventName\":[\"INSERT\",\"MODIFY\"]}",
        ]
      }
    }
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].batch_size == 10
    error_message = "An explicit batch size must reach the mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].starting_position == "TRIM_HORIZON"
    error_message = "TRIM_HORIZON must reach the mapping, which is how a consumer backfills from the start of the stream's retention window."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].maximum_batching_window_in_seconds == 5
    error_message = "An explicit batching window must reach the mapping."
  }

  assert {
    condition     = !aws_lambda_event_source_mapping.dynamodb_stream["issues"].bisect_batch_on_function_error
    error_message = "Bisecting must be switchable off for a handler that is not idempotent across a split batch."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].maximum_retry_attempts == 3
    error_message = "A retry cap must reach the mapping; without one a failing record blocks its shard until it expires."
  }

  assert {
    condition = jsondecode(
      tolist(aws_lambda_event_source_mapping.dynamodb_stream["issues"].filter_criteria[0].filter)[0].pattern
    ).eventName == ["INSERT", "MODIFY"]
    error_message = "A filter pattern must reach the mapping as the JSON string it was given. Filtering at the mapping is what stops an invocation being billed for a record the application would drop."
  }
}

run "an_sqs_on_failure_destination_adds_the_send_grant" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn                 = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
        on_failure_destination_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-stream-dlq"
      }
    }
  }

  assert {
    condition     = aws_lambda_event_source_mapping.dynamodb_stream["issues"].destination_config[0].on_failure[0].destination_arn == "arn:aws:sqs:us-west-2:123456789012:example-staging-stream-dlq"
    error_message = "The on failure destination must reach the mapping, or a discarded batch leaves no record of what was dropped."
  }

  assert {
    condition     = length(jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement) == 2
    error_message = "A destination the mapping writes to needs its own grant; without it the batch is discarded and the metadata never arrives."
  }

  assert {
    condition     = jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement[1].Action == ["sqs:SendMessage"]
    error_message = "SendMessage is all the mapping needs on an SQS destination."
  }

  assert {
    condition     = jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement[1].Resource == ["arn:aws:sqs:us-west-2:123456789012:example-staging-stream-dlq"]
    error_message = "The destination grant must name the destination ARN it was given alone."
  }
}

run "an_sns_on_failure_destination_grants_publish_instead" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn                 = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
        on_failure_destination_arn = "arn:aws:sns:us-west-2:123456789012:example-staging-stream-failures"
      }
    }
  }

  assert {
    condition     = jsondecode(local.dynamodb_stream_event_source_policy_json["issues"]).Statement[1].Action == ["sns:Publish"]
    error_message = "An SNS destination needs sns:Publish rather than sqs:SendMessage; the grant must follow the ARN's service."
  }
}

run "a_disabled_entry_creates_the_mapping_without_reading" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
        enabled    = false
      }
    }
  }

  assert {
    condition     = !aws_lambda_event_source_mapping.dynamodb_stream["issues"].enabled
    error_message = "enabled false must still create the mapping but stop it reading, which is how a consumer pauses without losing the mapping's shard position."
  }

  assert {
    condition     = length(aws_iam_role_policy.dynamodb_stream_event_source) == 1
    error_message = "A paused mapping still needs its grant in place, because enabling it again is an update rather than a create and nothing would re-attach the policy."
  }
}

run "two_streams_get_one_mapping_and_one_grant_each" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
      }
      comments = {
        stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-comments/stream/2026-09-17T00:00:00.000"
      }
    }
  }

  assert {
    condition     = length(aws_lambda_event_source_mapping.dynamodb_stream) == 2
    error_message = "Each map entry must produce its own mapping."
  }

  assert {
    condition     = aws_iam_role_policy.dynamodb_stream_event_source["comments"].name == "dynamodb-stream-event-source-comments"
    error_message = "The inline policy name must carry the map key, or two streams collide on one policy name and the second overwrites the first."
  }

  assert {
    condition     = jsondecode(local.dynamodb_stream_event_source_policy_json["comments"]).Statement[0].Resource == ["arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-comments/stream/2026-09-17T00:00:00.000"]
    error_message = "Each grant must be scoped to its own stream; a shared grant would let a compromised consumer read the other table's changes."
  }
}

run "a_queue_and_a_stream_share_one_pass_through_path" {
  command = plan

  variables {
    events_path = "/internal/events"

    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
      }
    }

    dynamodb_stream_event_sources = {
      issues = {
        stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
      }
    }
  }

  assert {
    condition = (
      local.environment_variables["AWS_LWA_PASS_THROUGH_PATH"] ==
      local.environment_variables["APP_EVENTS_PATH"]
    )
    error_message = "One input feeds both variables, so the path the adapter posts to is the path the application listens on by construction, whichever source kind is wired."
  }

  assert {
    condition     = output.events_path == "/internal/events"
    error_message = "An overridden events path must reach the output when a stream is the only wired source as well as when a queue is."
  }
}

run "a_stream_in_another_region_is_rejected" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn = "arn:aws:dynamodb:us-east-1:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
      }
    }
  }

  expect_failures = [aws_lambda_event_source_mapping.dynamodb_stream]
}

run "a_table_arn_in_place_of_a_stream_arn_is_rejected" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues"
      }
    }
  }

  expect_failures = [var.dynamodb_stream_event_sources]
}

run "an_unsupported_starting_position_is_rejected" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn        = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
        starting_position = "AT_TIMESTAMP"
      }
    }
  }

  expect_failures = [var.dynamodb_stream_event_sources]
}

run "a_filter_pattern_that_is_not_json_is_rejected" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn      = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
        filter_patterns = ["eventName = INSERT"]
      }
    }
  }

  expect_failures = [var.dynamodb_stream_event_sources]
}

run "an_on_failure_destination_that_is_neither_sqs_nor_sns_is_rejected" {
  command = plan

  variables {
    dynamodb_stream_event_sources = {
      issues = {
        stream_arn                 = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
        on_failure_destination_arn = "arn:aws:s3:::example-staging-stream-failures"
      }
    }
  }

  expect_failures = [var.dynamodb_stream_event_sources]
}

run "a_stream_without_the_module_owning_the_grant_is_rejected" {
  command = plan

  variables {
    attach_role_policies = false

    dynamodb_stream_event_sources = {
      issues = {
        stream_arn = "arn:aws:dynamodb:us-west-2:123456789012:table/example-staging-issues/stream/2026-09-17T00:00:00.000"
      }
    }
  }

  expect_failures = [var.attach_role_policies]
}
