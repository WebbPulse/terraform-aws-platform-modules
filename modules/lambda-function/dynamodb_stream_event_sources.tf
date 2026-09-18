resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  for_each = var.dynamodb_stream_event_sources

  event_source_arn  = each.value.stream_arn
  function_name     = aws_lambda_function.this.arn
  enabled           = each.value.enabled
  starting_position = each.value.starting_position

  batch_size                         = each.value.batch_size
  maximum_batching_window_in_seconds = each.value.maximum_batching_window_in_seconds
  bisect_batch_on_function_error     = each.value.bisect_batch_on_function_error
  maximum_retry_attempts             = each.value.maximum_retry_attempts

  function_response_types = ["ReportBatchItemFailures"]

  dynamic "filter_criteria" {
    for_each = length(each.value.filter_patterns) > 0 ? [each.value.filter_patterns] : []

    content {
      dynamic "filter" {
        for_each = filter_criteria.value

        content {
          pattern = filter.value
        }
      }
    }
  }

  dynamic "destination_config" {
    for_each = each.value.on_failure_destination_arn == null ? [] : [each.value.on_failure_destination_arn]

    content {
      on_failure {
        destination_arn = destination_config.value
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.dynamodb_stream_event_source_regions[each.key] == data.aws_region.current[0].region
      error_message = "The stream named in dynamodb_stream_event_sources is in a different region from this function. An event source mapping is regional: Lambda reads a stream in its own region only, and CreateEventSourceMapping fails on a cross-region ARN."
    }
  }

  depends_on = [aws_iam_role_policy.dynamodb_stream_event_source]
}

resource "aws_iam_role_policy" "dynamodb_stream_event_source" {
  for_each = var.attach_role_policies ? var.dynamodb_stream_event_sources : {}

  name   = "dynamodb-stream-event-source-${each.key}"
  role   = aws_iam_role.this.id
  policy = local.dynamodb_stream_event_source_policy_json[each.key]
}
