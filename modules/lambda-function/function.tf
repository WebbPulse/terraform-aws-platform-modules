data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = var.assume_role_service_principals
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

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = var.description
  role          = aws_iam_role.this.arn
  runtime       = var.runtime
  handler       = var.handler
  architectures = var.architectures
  memory_size   = var.memory_size
  timeout       = var.timeout
  publish       = var.publish
  layers        = var.layers

  reserved_concurrent_executions = var.reserved_concurrent_executions

  filename          = var.code.filename
  s3_bucket         = var.code.s3_bucket
  s3_key            = var.code.s3_key
  s3_object_version = var.code.s3_object_version
  image_uri         = var.code.image_uri
  source_code_hash  = var.code.source_code_hash

  dynamic "environment" {
    for_each = length(var.environment_variables) > 0 ? [1] : []

    content {
      variables = var.environment_variables
    }
  }

  dynamic "tracing_config" {
    for_each = var.tracing_mode == null ? [] : [var.tracing_mode]

    content {
      mode = tracing_config.value
    }
  }

  logging_config {
    log_format            = var.log_format
    application_log_level = var.application_log_level
    system_log_level      = var.system_log_level
    log_group             = var.set_logging_config_log_group ? aws_cloudwatch_log_group.this.name : null
  }

  dynamic "vpc_config" {
    for_each = var.vpc_config == null ? [] : [var.vpc_config]

    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  dynamic "ephemeral_storage" {
    for_each = var.ephemeral_storage_size == null ? [] : [var.ephemeral_storage_size]

    content {
      size = ephemeral_storage.value
    }
  }

  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash,
      s3_bucket,
      s3_key,
      s3_object_version,
    ]
  }

  depends_on = [aws_cloudwatch_log_group.this]

  tags = var.tags
}
