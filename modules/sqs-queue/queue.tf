resource "aws_sqs_queue" "dead_letter" {
  name       = local.dead_letter_queue_name
  fifo_queue = var.fifo_queue

  content_based_deduplication = local.content_based_deduplication
  deduplication_scope         = local.deduplication_scope
  fifo_throughput_limit       = local.fifo_throughput_limit

  visibility_timeout_seconds = local.dead_letter_visibility_timeout_seconds
  message_retention_seconds  = var.dead_letter_message_retention_seconds
  max_message_size           = var.max_message_size
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  sqs_managed_sse_enabled           = local.sqs_managed_sse_enabled
  kms_master_key_id                 = var.kms_master_key_id
  kms_data_key_reuse_period_seconds = local.kms_data_key_reuse_period_seconds

  tags = var.tags
}

resource "aws_sqs_queue" "this" {
  name       = local.queue_name
  fifo_queue = var.fifo_queue

  content_based_deduplication = local.content_based_deduplication
  deduplication_scope         = local.deduplication_scope
  fifo_throughput_limit       = local.fifo_throughput_limit

  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  delay_seconds              = var.delay_seconds
  max_message_size           = var.max_message_size
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  sqs_managed_sse_enabled           = local.sqs_managed_sse_enabled
  kms_master_key_id                 = var.kms_master_key_id
  kms_data_key_reuse_period_seconds = local.kms_data_key_reuse_period_seconds

  redrive_policy = jsonencode(local.redrive_policy)

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.minimum_visibility_timeout_seconds == null || var.visibility_timeout_seconds >= coalesce(local.minimum_visibility_timeout_seconds, 0)
      error_message = "visibility_timeout_seconds is less than six times consumer_timeout_seconds. A message stays invisible for the visibility timeout, and the event source mapping retries a batch inside that window, so a timeout shorter than six times the consumer's own hands the same message to a second invocation while the first is still working on it. Raise visibility_timeout_seconds, lower the consumer's timeout, or pass consumer_timeout_seconds as null to skip the check."
    }
  }
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  count = var.redrive_allow_policy_enabled ? 1 : 0

  queue_url = aws_sqs_queue.dead_letter.id

  redrive_allow_policy = jsonencode(local.redrive_allow_policy)
}

resource "aws_sqs_queue_policy" "this" {
  count = length(var.producer_role_arns) > 0 ? 1 : 0

  queue_url = aws_sqs_queue.this.id
  policy    = local.queue_policy_json
}
