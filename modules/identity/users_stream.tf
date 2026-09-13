resource "aws_lambda_event_source_mapping" "users_purge" {
  count = var.users_stream_enabled ? 1 : 0

  event_source_arn  = var.users_table_stream_arn
  function_name     = var.identity_function_name
  starting_position = var.users_stream_starting_position

  batch_size                         = var.users_stream_batch_size
  maximum_retry_attempts             = var.users_stream_maximum_retry_attempts
  bisect_batch_on_function_error     = true
  maximum_batching_window_in_seconds = var.users_stream_batching_window_seconds

  function_response_types = ["ReportBatchItemFailures"]

  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["REMOVE"]
      })
    }
  }

  lifecycle {
    precondition {
      condition     = var.users_table_stream_arn != null
      error_message = "users_stream_enabled is true but users_table_stream_arn is null. Pass the users table's stream_arn, usually module.tables.stream_arns[\"users\"], which is null until stream_view_type is set on that table."
    }

    precondition {
      condition     = var.identity_function_name != null
      error_message = "users_stream_enabled is true but identity_function_name is null. Pass the identity Lambda's function name so the event source mapping has a target."
    }
  }

  depends_on = [aws_iam_role_policy.users_stream]
}

resource "aws_iam_role_policy" "users_stream" {
  count = var.users_stream_enabled && var.attach_role_policies ? 1 : 0

  name   = "identity-users-stream"
  role   = var.identity_role_name
  policy = local.users_stream_policy_json
}
