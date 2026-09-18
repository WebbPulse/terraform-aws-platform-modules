locals {
  role_name      = coalesce(var.role_name, "${var.function_name}-role")
  log_group_name = coalesce(var.log_group_name, "/aws/lambda/${var.function_name}")

  sqs_environment = length(var.sqs_event_sources) > 0 ? {
    AWS_LWA_PASS_THROUGH_PATH = var.events_path
    APP_EVENTS_PATH           = var.events_path
  } : {}

  environment_variables = merge(var.environment_variables, local.sqs_environment, var.otel_environment_variables)

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
}
