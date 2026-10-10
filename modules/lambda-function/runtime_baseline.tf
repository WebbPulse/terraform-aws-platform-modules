data "aws_iam_policy_document" "runtime_baseline" {
  count = local.runtime_baseline_enabled ? 1 : 0

  dynamic "statement" {
    for_each = var.enable_log_write ? [1] : []

    content {
      sid       = "WriteOwnLogs"
      actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_xray ? [1] : []

    content {
      sid       = "WriteSpansToTheXRayOTLPEndpoint"
      actions   = ["xray:PutSpans", "xray:PutSpansForIndexing"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.app_secret_arns) > 0 ? [1] : []

    content {
      sid       = "ReadTheAppSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.app_secret_arns
    }
  }

  dynamic "statement" {
    for_each = length(var.kms_key_arns) > 0 ? [1] : []

    content {
      sid       = "DecryptWithTheGivenKeys"
      actions   = ["kms:Decrypt"]
      resources = var.kms_key_arns

      dynamic "condition" {
        for_each = length(var.kms_via_services) > 0 ? [1] : []

        content {
          test     = "StringEquals"
          variable = "kms:ViaService"
          values   = var.kms_via_services
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "runtime_baseline" {
  count = local.runtime_baseline_enabled ? 1 : 0

  name   = var.runtime_baseline_policy_name
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.runtime_baseline[0].json
}
