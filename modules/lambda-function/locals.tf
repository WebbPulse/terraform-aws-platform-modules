locals {
  role_name      = coalesce(var.role_name, "${var.function_name}-role")
  log_group_name = coalesce(var.log_group_name, "/aws/lambda/${var.function_name}")

  any_event_source = length(var.sqs_event_sources) > 0 || length(var.dynamodb_stream_event_sources) > 0

  events_environment = local.any_event_source ? {
    AWS_LWA_PASS_THROUGH_PATH = var.events_path
    APP_EVENTS_PATH           = var.events_path
  } : {}

  environment_variables = merge(var.environment_variables, local.events_environment, var.otel_environment_variables)

  attach_xray_write_policy = var.attach_xray_write_policy && var.tracing_mode == "Active"

  sqs_consume_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes",
  ]

  sqs_event_source_policy_json = {
    for key, source in var.sqs_event_sources : key => jsonencode({
      Version = "2012-10-17"
      Statement = concat(
        [
          {
            Sid      = "ConsumeTheQueue"
            Effect   = "Allow"
            Action   = local.sqs_consume_actions
            Resource = [source.queue_arn]
          },
        ],
        source.kms_key_arn == null ? [] : [
          {
            Sid      = "DecryptTheQueuesMessages"
            Effect   = "Allow"
            Action   = ["kms:Decrypt"]
            Resource = [source.kms_key_arn]
          },
        ],
      )
    })
  }

  sqs_event_source_regions = {
    for key, source in var.sqs_event_sources : key => split(":", source.queue_arn)[3]
  }

  dynamodb_stream_read_actions = [
    "dynamodb:DescribeStream",
    "dynamodb:GetRecords",
    "dynamodb:GetShardIterator",
    "dynamodb:ListStreams",
  ]

  dynamodb_stream_on_failure_actions = {
    sqs = ["sqs:SendMessage"]
    sns = ["sns:Publish"]
  }

  dynamodb_stream_event_source_policy_json = {
    for key, source in var.dynamodb_stream_event_sources : key => jsonencode({
      Version = "2012-10-17"
      Statement = concat(
        [
          {
            Sid      = "ReadTheTableStream"
            Effect   = "Allow"
            Action   = local.dynamodb_stream_read_actions
            Resource = [source.stream_arn]
          },
        ],
        source.on_failure_destination_arn == null ? [] : [
          {
            Sid      = "WriteTheDiscardedBatchToTheDestination"
            Effect   = "Allow"
            Action   = local.dynamodb_stream_on_failure_actions[split(":", source.on_failure_destination_arn)[2]]
            Resource = [source.on_failure_destination_arn]
          },
        ],
      )
    })
  }

  dynamodb_stream_event_source_regions = {
    for key, source in var.dynamodb_stream_event_sources : key => split(":", source.stream_arn)[3]
  }
}
