locals {
  fifo_suffix = var.fifo_queue ? ".fifo" : ""

  queue_name             = "${var.name}${local.fifo_suffix}"
  dead_letter_queue_name = "${var.name}${var.dead_letter_queue_suffix}${local.fifo_suffix}"

  sqs_managed_sse_enabled           = var.kms_master_key_id == null ? true : null
  kms_data_key_reuse_period_seconds = var.kms_master_key_id == null ? null : var.kms_data_key_reuse_period_seconds

  content_based_deduplication = var.fifo_queue ? var.content_based_deduplication : null
  deduplication_scope         = var.fifo_queue ? var.deduplication_scope : null
  fifo_throughput_limit       = var.fifo_queue ? var.fifo_throughput_limit : null

  dead_letter_visibility_timeout_seconds = coalesce(
    var.dead_letter_visibility_timeout_seconds,
    var.visibility_timeout_seconds,
  )

  minimum_visibility_timeout_seconds = var.consumer_timeout_seconds == null ? null : 6 * var.consumer_timeout_seconds

  redrive_policy = {
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = var.max_receive_count
  }

  redrive_allow_policy = {
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this.arn]
  }

  queue_policy = length(var.producer_role_arns) == 0 ? null : {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SendToTheQueue"
        Effect = "Allow"
        Principal = {
          AWS = var.producer_role_arns
        }
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueUrl",
        ]
        Resource = aws_sqs_queue.this.arn
      },
    ]
  }

  queue_policy_json = local.queue_policy == null ? null : jsonencode(local.queue_policy)
}
