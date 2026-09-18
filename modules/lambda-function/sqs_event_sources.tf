data "aws_region" "current" {
  count = length(var.sqs_event_sources) > 0 ? 1 : 0
}

resource "aws_lambda_event_source_mapping" "sqs" {
  for_each = var.sqs_event_sources

  event_source_arn = each.value.queue_arn
  function_name    = aws_lambda_function.this.arn
  enabled          = each.value.enabled

  batch_size                         = each.value.batch_size
  maximum_batching_window_in_seconds = each.value.maximum_batching_window_seconds
  function_response_types            = each.value.function_response_types

  dynamic "filter_criteria" {
    for_each = length(each.value.filter_criteria) > 0 ? [each.value.filter_criteria] : []

    content {
      dynamic "filter" {
        for_each = filter_criteria.value

        content {
          pattern = jsonencode(filter.value)
        }
      }
    }
  }

  dynamic "scaling_config" {
    for_each = each.value.maximum_concurrency == null ? [] : [each.value.maximum_concurrency]

    content {
      maximum_concurrency = scaling_config.value
    }
  }

  lifecycle {
    precondition {
      condition     = local.sqs_event_source_regions[each.key] == data.aws_region.current[0].region
      error_message = "The queue named in sqs_event_sources is in a different region from this function. An event source mapping is regional: Lambda polls a queue in its own region only, and CreateEventSourceMapping fails on a cross-region ARN."
    }
  }

  depends_on = [aws_iam_role_policy.sqs_event_source]
}

resource "aws_iam_role_policy" "sqs_event_source" {
  for_each = var.attach_role_policies ? var.sqs_event_sources : {}

  name   = "sqs-event-source-${each.key}"
  role   = aws_iam_role.this.id
  policy = local.sqs_event_source_policy_json[each.key]
}
