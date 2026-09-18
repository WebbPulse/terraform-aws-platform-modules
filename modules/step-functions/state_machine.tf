data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = local.role_name
  path                 = var.role_path
  description          = var.role_description
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.role_tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_group_kms_key_id
  tags              = var.log_group_tags
}

data "aws_iam_policy_document" "logging" {
  statement {
    sid = "VendedLogDelivery"

    actions = [
      "logs:CreateLogDelivery",
      "logs:CreateLogStream",
      "logs:DeleteLogDelivery",
      "logs:DescribeLogGroups",
      "logs:DescribeResourcePolicies",
      "logs:GetLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutLogEvents",
      "logs:PutResourcePolicy",
      "logs:UpdateLogDelivery",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "logging" {
  name   = "logging"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.logging.json
}

data "aws_iam_policy_document" "xray_write" {
  count = local.attach_xray_write_policy ? 1 : 0

  statement {
    sid = "XRayWrite"

    actions = [
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "xray_write" {
  count = local.attach_xray_write_policy ? 1 : 0

  name   = "xray-write"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.xray_write[0].json
}

resource "aws_iam_role_policy" "work" {
  count = length(local.policy_statements) > 0 ? 1 : 0

  name = var.policy_name
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policy_statements
  })
}

resource "aws_sfn_state_machine" "this" {
  lifecycle {
    precondition {
      condition     = can(jsondecode(local.definition))
      error_message = "definition must be valid JSON once definition_substitutions have been substituted into it. A definition built with jsonencode is always valid; a hand-written file with a trailing comma is not, and neither is one whose substituted value carries a bare quote."
    }

    precondition {
      condition     = can(jsondecode(local.definition).States)
      error_message = "definition must carry a States object once substituted. A definition without one is rejected at apply with a validation error that does not name the missing field."
    }
  }

  name     = var.name
  type     = var.type
  role_arn = aws_iam_role.this.arn
  publish  = var.publish

  definition = local.definition

  logging_configuration {
    level                  = var.log_level
    include_execution_data = var.include_execution_data
    log_destination        = var.log_level == "OFF" ? null : "${aws_cloudwatch_log_group.this.arn}:*"
  }

  tracing_configuration {
    enabled = var.tracing_enabled
  }

  depends_on = [aws_iam_role_policy.logging]

  tags = var.tags
}
