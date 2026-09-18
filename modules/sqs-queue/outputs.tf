output "queue_arn" {
  description = "ARN of the queue, which is what an event source mapping and an IAM grant name. This is the value the lambda-function module's sqs_event_sources takes as queue_arn."
  value       = aws_sqs_queue.this.arn
}

output "queue_url" {
  description = "URL of the queue, which is what every SQS API call takes rather than the ARN. A producer sends to this."
  value       = aws_sqs_queue.this.url
}

output "queue_name" {
  description = "Name of the queue, with the .fifo suffix on a FIFO queue. This is the CloudWatch QueueName dimension."
  value       = aws_sqs_queue.this.name
}

output "queue_id" {
  description = "Id of the queue, which for SQS is its URL. The same string as queue_url, under the other convention."
  value       = aws_sqs_queue.this.id
}

output "dead_letter_queue_arn" {
  description = "ARN of the dead letter queue. An alarm on its ApproximateNumberOfMessagesVisible is what tells you the consumer is parking messages."
  value       = aws_sqs_queue.dead_letter.arn
}

output "dead_letter_queue_url" {
  description = "URL of the dead letter queue, for a redrive or for draining it by hand."
  value       = aws_sqs_queue.dead_letter.url
}

output "dead_letter_queue_name" {
  description = "Name of the dead letter queue, with the .fifo suffix on a FIFO queue. This is the CloudWatch QueueName dimension."
  value       = aws_sqs_queue.dead_letter.name
}

output "kms_master_key_id" {
  description = "Key encrypting both queues, echoing the input. Null on an SSE-SQS queue, where there is no customer key for a producer or consumer to be granted on."
  value       = var.kms_master_key_id
}

output "queue_policy_json" {
  description = "Queue policy granting producer_role_arns sqs:SendMessage and sqs:GetQueueUrl, null when no producer was named. Already attached to the queue; this output is for a consumer composing one policy out of several statements."
  value       = local.queue_policy_json
}
