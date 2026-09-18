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
    condition     = length(aws_lambda_event_source_mapping.sqs) == 0
    error_message = "An SQS event source must be opt-in: a consumer that names no queue has nothing for this function to poll, and an existing consumer must see no plan change."
  }

  assert {
    condition     = length(aws_iam_role_policy.sqs_event_source) == 0
    error_message = "With no queue to poll there is no queue to grant, so the inline policy must not be created."
  }

  assert {
    condition     = !contains(keys(local.environment_variables), "AWS_LWA_PASS_THROUGH_PATH")
    error_message = "Pass through must stay off by default. Turning it on without a package that mounts the route makes the adapter post to a path that 404s, and the mapping then retries the batch until the redrive policy gives up."
  }

  assert {
    condition     = !contains(keys(local.environment_variables), "APP_EVENTS_PATH")
    error_message = "APP_EVENTS_PATH must be absent when no queue is wired."
  }

  assert {
    condition     = output.events_path == null
    error_message = "The events_path output must be null when no mapping exists, so a consumer branching on it does not advertise a route the function does not serve."
  }
}

run "a_queue_creates_the_mapping_the_grant_and_the_pass_through" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
      }
    }
  }

  assert {
    condition     = length(aws_lambda_event_source_mapping.sqs) == 1
    error_message = "One queue entry must create exactly one event source mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.sqs["jobs"].event_source_arn == "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
    error_message = "The mapping must poll the queue ARN it was given, unchanged."
  }

  assert {
    condition     = contains(aws_lambda_event_source_mapping.sqs["jobs"].function_response_types, "ReportBatchItemFailures")
    error_message = "Without ReportBatchItemFailures a single failed message replays the whole batch, so every message that already succeeded is delivered again and the work is done twice."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.sqs["jobs"].enabled
    error_message = "A mapping must poll by default; a disabled mapping is a queue that silently fills up."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.sqs["jobs"].batch_size == 10
    error_message = "The default batch size must reach the mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.sqs["jobs"].maximum_batching_window_in_seconds == 5
    error_message = "The default batching window must reach the mapping; it is what collapses a burst into far fewer invocations."
  }

  assert {
    condition     = length(aws_lambda_event_source_mapping.sqs["jobs"].scaling_config) == 0
    error_message = "With no maximum_concurrency the scaling_config block must be left out entirely rather than written with a null, because an absent block means the function's own unreserved concurrency applies."
  }

  assert {
    condition     = length(aws_iam_role_policy.sqs_event_source) == 1
    error_message = "With attach_role_policies on, the queue read grant must be attached: Lambda checks it during the CreateEventSourceMapping call."
  }

  assert {
    condition = alltrue([
      for action in ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"] :
      contains(jsondecode(local.sqs_event_source_policy_json["jobs"]).Statement[0].Action, action)
    ])
    error_message = "The poller needs all three queue actions; missing one leaves the mapping retrying with no messages delivered, or delivering messages it can never delete."
  }

  assert {
    condition     = length(jsondecode(local.sqs_event_source_policy_json["jobs"]).Statement[0].Action) == 3
    error_message = "The grant must be exactly the three actions a poller calls. sqs:* on a queue also grants SendMessage and PurgeQueue, which a consumer has no reason to hold."
  }

  assert {
    condition     = jsondecode(local.sqs_event_source_policy_json["jobs"]).Statement[0].Resource == ["arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"]
    error_message = "The grant must name the queue ARN alone rather than a wildcard."
  }

  assert {
    condition     = length(jsondecode(local.sqs_event_source_policy_json["jobs"]).Statement) == 1
    error_message = "With no kms_key_arn there is no key to decrypt with, so the policy must carry the queue statement alone."
  }

  assert {
    condition     = local.environment_variables["AWS_LWA_PASS_THROUGH_PATH"] == "/events"
    error_message = "The adapter reads AWS_LWA_PASS_THROUGH_PATH to know where to post a non-HTTP invocation, which is how an SQS batch reaches the FastAPI app."
  }

  assert {
    condition     = local.environment_variables["APP_EVENTS_PATH"] == "/events"
    error_message = "The application reads APP_EVENTS_PATH to know where to mount the event route."
  }
}

run "the_adapter_path_and_the_route_path_cannot_drift" {
  command = plan

  variables {
    events_path = "/internal/events"

    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
      }
    }
  }

  assert {
    condition = (
      local.environment_variables["AWS_LWA_PASS_THROUGH_PATH"] ==
      local.environment_variables["APP_EVENTS_PATH"]
    )
    error_message = "One input feeds both variables, so the path the adapter posts to is the path the application listens on by construction."
  }

  assert {
    condition     = output.events_path == "/internal/events"
    error_message = "An overridden events path must reach the output as well as the environment."
  }
}

run "an_explicit_environment_variable_wins_over_the_derived_pass_through" {
  command = plan

  variables {
    otel_environment_variables = {
      AWS_LWA_PASS_THROUGH_PATH = "/otel/events"
    }

    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
      }
    }
  }

  assert {
    condition     = local.environment_variables["AWS_LWA_PASS_THROUGH_PATH"] == "/otel/events"
    error_message = "otel_environment_variables is documented as merged last, so a consumer that already sets the adapter's variable by hand must keep winning; silently overriding it would move the route out from under a working deployment."
  }
}

run "a_kms_key_adds_the_decrypt_statement" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn   = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
        kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
      }
    }
  }

  assert {
    condition     = length(jsondecode(local.sqs_event_source_policy_json["jobs"]).Statement) == 2
    error_message = "A queue encrypted with a customer key needs kms:Decrypt as well; without it the poller receives nothing and the failure is an access denied on the key, not on the queue."
  }

  assert {
    condition     = jsondecode(local.sqs_event_source_policy_json["jobs"]).Statement[1].Action == ["kms:Decrypt"]
    error_message = "Decrypt is all a consumer needs on the queue's key: the producer does the GenerateDataKey."
  }

  assert {
    condition     = jsondecode(local.sqs_event_source_policy_json["jobs"]).Statement[1].Resource == ["arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"]
    error_message = "The decrypt grant must name the key ARN it was given alone."
  }
}

run "a_filter_and_a_scaling_config_reach_the_mapping" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn                       = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
        batch_size                      = 25
        maximum_batching_window_seconds = 30
        maximum_concurrency             = 20

        filter_criteria = [
          {
            body = {
              kind = ["purge"]
            }
          },
        ]
      }
    }
  }

  assert {
    condition     = aws_lambda_event_source_mapping.sqs["jobs"].batch_size == 25
    error_message = "An explicit batch size must reach the mapping."
  }

  assert {
    condition     = aws_lambda_event_source_mapping.sqs["jobs"].scaling_config[0].maximum_concurrency == 20
    error_message = "maximum_concurrency is what stops a queue burst from consuming every unreserved concurrent execution in the account, so it must reach the scaling_config block."
  }

  assert {
    condition = jsondecode(
      tolist(aws_lambda_event_source_mapping.sqs["jobs"].filter_criteria[0].filter)[0].pattern
    ).body.kind == ["purge"]
    error_message = "A filter pattern must reach the mapping encoded as JSON. Filtering at the mapping is what stops an invocation being billed for a message the application would drop."
  }
}

run "a_disabled_entry_creates_the_mapping_without_polling" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
        enabled   = false
      }
    }
  }

  assert {
    condition     = !aws_lambda_event_source_mapping.sqs["jobs"].enabled
    error_message = "enabled false must still create the mapping but stop it polling, which is how a consumer pauses a consumer without losing the mapping's redrive state."
  }

  assert {
    condition     = length(aws_iam_role_policy.sqs_event_source) == 1
    error_message = "A paused mapping still needs its grant in place, because enabling it again is an update rather than a create and nothing would re-attach the policy."
  }
}

run "two_queues_get_one_mapping_and_one_grant_each" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
      }
      emails = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-emails"
      }
    }
  }

  assert {
    condition     = length(aws_lambda_event_source_mapping.sqs) == 2
    error_message = "Each map entry must produce its own mapping."
  }

  assert {
    condition     = length(aws_iam_role_policy.sqs_event_source) == 2
    error_message = "Each queue must get its own grant naming only itself, rather than one policy listing every queue."
  }

  assert {
    condition     = aws_iam_role_policy.sqs_event_source["emails"].name == "sqs-event-source-emails"
    error_message = "The inline policy name must carry the map key, or two queues collide on one policy name and the second overwrites the first."
  }

  assert {
    condition     = jsondecode(local.sqs_event_source_policy_json["emails"]).Statement[0].Resource == ["arn:aws:sqs:us-west-2:123456789012:example-staging-emails"]
    error_message = "Each grant must be scoped to its own queue; a shared grant would let a compromised consumer drain the other queue."
  }
}

run "a_queue_in_another_region_is_rejected" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-east-1:123456789012:example-staging-jobs"
      }
    }
  }

  expect_failures = [aws_lambda_event_source_mapping.sqs]
}

run "a_queue_url_in_place_of_an_arn_is_rejected" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn = "https://sqs.us-west-2.amazonaws.com/123456789012/example-staging-jobs"
      }
    }
  }

  expect_failures = [var.sqs_event_sources]
}

run "a_large_batch_without_a_batching_window_is_rejected" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn                       = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
        batch_size                      = 50
        maximum_batching_window_seconds = 0
      }
    }
  }

  expect_failures = [var.sqs_event_sources]
}

run "a_maximum_concurrency_below_the_service_floor_is_rejected" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn           = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
        maximum_concurrency = 1
      }
    }
  }

  expect_failures = [var.sqs_event_sources]
}

run "a_kms_alias_in_place_of_a_key_arn_is_rejected" {
  command = plan

  variables {
    sqs_event_sources = {
      jobs = {
        queue_arn   = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
        kms_key_arn = "arn:aws:kms:us-west-2:123456789012:alias/example-staging-jobs"
      }
    }
  }

  expect_failures = [var.sqs_event_sources]
}

run "a_queue_without_the_module_owning_the_grant_is_rejected" {
  command = plan

  variables {
    attach_role_policies = false

    sqs_event_sources = {
      jobs = {
        queue_arn = "arn:aws:sqs:us-west-2:123456789012:example-staging-jobs"
      }
    }
  }

  expect_failures = [var.attach_role_policies]
}

run "an_events_path_without_a_leading_slash_is_rejected" {
  command = plan

  variables {
    events_path = "events"
  }

  expect_failures = [var.events_path]
}
