variables {
  name = "example-staging-jobs"
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

run "the_defaults_are_a_standard_queue_with_a_dead_letter_queue_behind_it" {
  command = plan

  assert {
    condition     = aws_sqs_queue.this.name == "example-staging-jobs"
    error_message = "A standard queue must take the name as given, with no suffix."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter.name == "example-staging-jobs-dlq"
    error_message = "The dead letter queue must be named after the queue it parks messages from, so the pair is obvious in the console."
  }

  assert {
    condition     = !aws_sqs_queue.this.fifo_queue
    error_message = "A queue must be standard by default: FIFO caps throughput and cannot be turned off after the create."
  }

  assert {
    condition     = local.redrive_policy.maxReceiveCount == 5
    error_message = "The redrive policy must carry the max receive count, or a poison message is retried until it ages out rather than being parked."
  }

  assert {
    condition     = aws_sqs_queue.this.sqs_managed_sse_enabled
    error_message = "SSE-SQS must be on by default. It costs nothing per request, and a queue with no encryption at all is not a default worth shipping."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter.sqs_managed_sse_enabled
    error_message = "A parked message is the one most likely to sit around for two weeks, so the dead letter queue must be encrypted too."
  }

  assert {
    condition     = aws_sqs_queue.this.kms_master_key_id == null
    error_message = "With no key given the queue must stay on the managed key rather than naming a customer one."
  }

  assert {
    condition     = aws_sqs_queue.this.visibility_timeout_seconds == 180
    error_message = "The default visibility timeout must reach the queue."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter.message_retention_seconds == 1209600
    error_message = "A parked message must be kept the full fourteen days: it only landed there because something is wrong, and the point is that someone can still look at it."
  }

  assert {
    condition     = length(aws_sqs_queue_policy.this) == 0
    error_message = "With no producer named there is nothing to grant, so no queue policy must be written."
  }

  assert {
    condition     = output.queue_policy_json == null
    error_message = "The policy output must be null when no producer was named, so a consumer merging it into its own document can branch on it."
  }
}

run "the_dead_letter_queue_only_accepts_this_queue_as_a_source" {
  command = plan

  assert {
    condition     = length(aws_sqs_queue_redrive_allow_policy.dead_letter) == 1
    error_message = "Without a redrive allow policy any queue in the account may nominate this dead letter queue, so the parked messages stop being attributable to one source."
  }

  assert {
    condition     = local.redrive_allow_policy.redrivePermission == "byQueue"
    error_message = "The allow policy must name specific source queues rather than allowing all."
  }
}

run "a_redrive_allow_policy_can_be_turned_off" {
  command = plan

  variables {
    redrive_allow_policy_enabled = false
  }

  assert {
    condition     = length(aws_sqs_queue_redrive_allow_policy.dead_letter) == 0
    error_message = "A consumer sharing one dead letter queue across several source queues must be able to leave the allow policy off."
  }
}

run "a_fifo_queue_gets_the_suffix_on_both_names" {
  command = plan

  variables {
    fifo_queue                  = true
    content_based_deduplication = true
    deduplication_scope         = "messageGroup"
    fifo_throughput_limit       = "perMessageGroupId"
  }

  assert {
    condition     = aws_sqs_queue.this.name == "example-staging-jobs.fifo"
    error_message = "SQS rejects a FIFO queue whose name does not end in .fifo, so the module must append it rather than making every consumer remember."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter.name == "example-staging-jobs-dlq.fifo"
    error_message = "A FIFO queue's dead letter queue must also be FIFO, and so must also carry the suffix."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter.fifo_queue
    error_message = "SQS rejects a redrive policy pointing a FIFO queue at a standard dead letter queue."
  }

  assert {
    condition     = local.content_based_deduplication
    error_message = "Content based deduplication must reach the FIFO queue when asked for."
  }

  assert {
    condition     = local.fifo_throughput_limit == "perMessageGroupId"
    error_message = "High throughput mode must reach the queue; it is the only way past the 300 call per second FIFO limit."
  }
}

run "the_fifo_settings_are_left_off_a_standard_queue" {
  command = plan

  variables {
    deduplication_scope   = "messageGroup"
    fifo_throughput_limit = "perMessageGroupId"
  }

  assert {
    condition     = local.deduplication_scope == null
    error_message = "SQS rejects a deduplication scope on a standard queue, so the module must drop it rather than pass it through."
  }

  assert {
    condition     = local.fifo_throughput_limit == null
    error_message = "SQS rejects a throughput limit on a standard queue, so the module must drop it rather than pass it through."
  }
}

run "a_visibility_timeout_at_six_times_the_consumer_timeout_is_accepted" {
  command = plan

  variables {
    consumer_timeout_seconds   = 30
    visibility_timeout_seconds = 180
  }

  assert {
    condition     = aws_sqs_queue.this.visibility_timeout_seconds == 180
    error_message = "Exactly six times the consumer timeout is the documented floor, not a violation of it."
  }
}

run "a_visibility_timeout_below_six_times_the_consumer_timeout_is_rejected" {
  command = plan

  variables {
    consumer_timeout_seconds   = 30
    visibility_timeout_seconds = 60
  }

  expect_failures = [aws_sqs_queue.this]
}

run "the_visibility_timeout_check_is_skipped_when_no_consumer_timeout_is_given" {
  command = plan

  variables {
    visibility_timeout_seconds = 30
  }

  assert {
    condition     = aws_sqs_queue.this.visibility_timeout_seconds == 30
    error_message = "A queue with no Lambda consumer must not be held to the consumer rule, so a null consumer_timeout_seconds has to skip the check entirely."
  }
}

run "the_dead_letter_queue_follows_the_main_visibility_timeout_unless_told_otherwise" {
  command = plan

  variables {
    consumer_timeout_seconds               = 30
    visibility_timeout_seconds             = 300
    dead_letter_visibility_timeout_seconds = 30
  }

  assert {
    condition     = aws_sqs_queue.dead_letter.visibility_timeout_seconds == 30
    error_message = "The dead letter queue's own timeout must be settable, and must not be held to the consumer rule: a dead letter queue is drained by hand or by a redrive, not by the consumer."
  }
}

run "a_customer_key_turns_managed_encryption_off_on_both_queues" {
  command = plan

  variables {
    kms_master_key_id = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = local.sqs_managed_sse_enabled == null
    error_message = "SQS rejects a queue configured with both SSE-SQS and a customer key, and the provider rejects the two arguments together even when one is null, so naming a key must leave the managed setting out entirely."
  }

  assert {
    condition     = aws_sqs_queue.this.kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "The key must reach the queue unchanged."
  }

  assert {
    condition     = aws_sqs_queue.dead_letter.kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "A parked message is a copy of the original, so the dead letter queue must be encrypted with the same key rather than falling back to the managed one."
  }

  assert {
    condition     = local.kms_data_key_reuse_period_seconds == 300
    error_message = "The data key reuse period must reach a customer key queue; it is what bounds how many KMS calls the queue is billed for."
  }

  assert {
    condition     = output.kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "The key must reach the output, because a producer and a consumer both need their own grant on it."
  }
}

run "a_producer_gets_send_and_nothing_else" {
  command = plan

  variables {
    producer_role_arns = ["arn:aws:iam::123456789012:role/example-staging-api-role"]
  }

  assert {
    condition     = length(aws_sqs_queue_policy.this) == 1
    error_message = "Naming a producer must write the queue policy that grants it."
  }

  assert {
    condition     = tolist(local.queue_policy.Statement[0].Principal.AWS) == tolist(["arn:aws:iam::123456789012:role/example-staging-api-role"])
    error_message = "The queue policy must name the producer roles it was given as its principals."
  }

  assert {
    condition = alltrue([
      for action in local.queue_policy.Statement[0].Action :
      contains(["sqs:SendMessage", "sqs:GetQueueUrl"], action)
    ])
    error_message = "A producer needs to send and to find the queue and nothing more. ReceiveMessage or DeleteMessage here would let a producer drain the queue out from under its consumer."
  }

  assert {
    condition     = length(local.queue_policy.Statement[0].Action) == 2
    error_message = "The producer grant must be exactly the two actions a sender calls."
  }
}

run "two_producers_share_one_statement" {
  command = plan

  variables {
    producer_role_arns = [
      "arn:aws:iam::123456789012:role/example-staging-api-role",
      "arn:aws:iam::123456789012:role/example-staging-worker-role",
    ]
  }

  assert {
    condition     = length(local.queue_policy.Statement) == 1
    error_message = "Every producer holds the same grant, so they belong in one statement's principal list rather than one statement each."
  }

  assert {
    condition     = length(local.queue_policy.Statement[0].Principal.AWS) == 2
    error_message = "Both producers must appear as principals."
  }
}

run "a_session_arn_in_place_of_a_role_arn_is_rejected" {
  command = plan

  variables {
    producer_role_arns = ["arn:aws:sts::123456789012:assumed-role/example-staging-api-role/session"]
  }

  expect_failures = [var.producer_role_arns]
}

run "deduplication_on_a_standard_queue_is_rejected" {
  command = plan

  variables {
    content_based_deduplication = true
  }

  expect_failures = [var.content_based_deduplication]
}

run "a_max_receive_count_of_zero_is_rejected" {
  command = plan

  variables {
    max_receive_count = 0
  }

  expect_failures = [var.max_receive_count]
}

run "a_visibility_timeout_above_twelve_hours_is_rejected" {
  command = plan

  variables {
    visibility_timeout_seconds = 43201
  }

  expect_failures = [var.visibility_timeout_seconds]
}

run "a_retention_beyond_fourteen_days_is_rejected" {
  command = plan

  variables {
    message_retention_seconds = 1209601
  }

  expect_failures = [var.message_retention_seconds]
}

run "a_name_that_leaves_no_room_for_the_suffixes_is_rejected" {
  command = plan

  variables {
    name = "example-staging-a-queue-name-that-runs-right-up-to-the-eighty-character-service-limit"
  }

  expect_failures = [var.name]
}
