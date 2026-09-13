resource "aws_lambda_event_source_mapping" "users_purge" {
  count = local.users_stream_enabled ? 1 : 0

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

  depends_on = [aws_iam_role_policy.users_stream]
}

resource "aws_iam_role_policy" "users_stream" {
  count = local.users_stream_enabled && var.attach_role_policies ? 1 : 0

  name   = "identity-users-stream"
  role   = var.identity_role_name
  policy = local.users_stream_policy_json
}
