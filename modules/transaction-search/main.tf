data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  policy_log_group_names = compact([
    var.spans_log_group_name,
    var.application_signals_log_group_name,
  ])

  policy_log_group_arns = [
    for name in local.policy_log_group_names :
    "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${name}:*"
  ]

  spans_log_groups = var.adopt_spans_log_group ? toset([var.spans_log_group_name]) : toset([])
}

data "aws_iam_policy_document" "spans" {
  statement {
    sid    = "TransactionSearchAccess"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["xray.amazonaws.com"]
    }

    actions = ["logs:PutLogEvents"]

    resources = local.policy_log_group_arns

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:xray:${local.region}:${local.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "spans" {
  policy_name     = "${var.name_prefix}${var.resource_policy_name_suffix}"
  policy_document = data.aws_iam_policy_document.spans.json
}

resource "aws_xray_trace_segment_destination" "this" {
  destination = "CloudWatchLogs"

  depends_on = [aws_cloudwatch_log_resource_policy.spans]
}

import {
  for_each = local.spans_log_groups

  to = aws_cloudwatch_log_group.spans[each.key]
  id = each.value
}

resource "aws_cloudwatch_log_group" "spans" {
  for_each = local.spans_log_groups

  name              = each.value
  retention_in_days = var.spans_log_group_retention_in_days
  tags              = var.tags

  depends_on = [aws_xray_trace_segment_destination.this]
}

resource "aws_xray_indexing_rule" "default" {
  count = var.create_indexing_rule ? 1 : 0

  name = "Default"

  rule {
    probabilistic {
      desired_sampling_percentage = var.indexing_rule_sampling_percentage
    }
  }

  depends_on = [aws_xray_trace_segment_destination.this]
}
