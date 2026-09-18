variable "name" {
  description = "Name of the queue, for example \"example-staging-jobs\". The dead letter queue is named after it with dead_letter_queue_suffix appended. On a FIFO queue the module appends \".fifo\" to both, so leave the suffix off this input. Changing the name replaces the queue, which discards every message still in it."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,75}$", var.name))
    error_message = "name must be 1 to 75 characters of letters, digits, hyphens and underscores. SQS allows 80, and the module needs the remainder for the dead letter suffix and the .fifo suffix."
  }
}

variable "fifo_queue" {
  description = "Make this a FIFO queue, which orders messages within a group and is the only way to get exactly-once processing out of SQS. The module appends the required \".fifo\" suffix to both queue names. A FIFO queue is not interchangeable with a standard one: the type cannot be changed after the create, and a Lambda event source mapping on a FIFO queue orders by message group, so a slow group holds up only itself."
  type        = bool
  default     = false
}

variable "content_based_deduplication" {
  description = "Derive a FIFO queue's deduplication id from a SHA-256 of the message body instead of requiring the producer to send one. Ignored on a standard queue. Leave it off when two distinct messages can legitimately carry the same body, because the second would be silently dropped inside the five minute deduplication interval."
  type        = bool
  default     = false

  validation {
    condition     = var.fifo_queue || !var.content_based_deduplication
    error_message = "content_based_deduplication only applies to a FIFO queue. Set fifo_queue true or leave deduplication off."
  }
}

variable "deduplication_scope" {
  description = "Whether a FIFO queue deduplicates per message group or across the whole queue: \"messageGroup\" or \"queue\". Null leaves SQS on its own default of queue. messageGroup is what high throughput mode requires."
  type        = string
  default     = null

  validation {
    condition     = var.deduplication_scope == null || contains(["messageGroup", "queue"], coalesce(var.deduplication_scope, "queue"))
    error_message = "deduplication_scope must be messageGroup or queue, or null to leave it unset."
  }
}

variable "fifo_throughput_limit" {
  description = "Whether a FIFO queue's throughput quota applies per message group or to the whole queue: \"perMessageGroupId\" or \"perQueue\". Null leaves SQS on perQueue. perMessageGroupId is high throughput mode and needs deduplication_scope set to messageGroup."
  type        = string
  default     = null

  validation {
    condition     = var.fifo_throughput_limit == null || contains(["perMessageGroupId", "perQueue"], coalesce(var.fifo_throughput_limit, "perQueue"))
    error_message = "fifo_throughput_limit must be perMessageGroupId or perQueue, or null to leave it unset."
  }
}

variable "visibility_timeout_seconds" {
  description = <<-EOT
    How long a message stays invisible to other consumers after one receive, 0 to 43200.

    It must be at least six times the consumer's own timeout, which is the rule Lambda documents for
    an SQS event source: the poller can retry a batch inside one visibility window, and a timeout
    shorter than the function's own hands the same message to a second invocation while the first is
    still working on it. Pass consumer_timeout_seconds to have that checked at plan time.
  EOT

  type    = number
  default = 180

  validation {
    condition     = var.visibility_timeout_seconds >= 0 && var.visibility_timeout_seconds <= 43200 && floor(var.visibility_timeout_seconds) == var.visibility_timeout_seconds
    error_message = "visibility_timeout_seconds must be a whole number from 0 to 43200, which is 12 hours."
  }
}

variable "consumer_timeout_seconds" {
  description = "Timeout of the Lambda that consumes this queue, usually the lambda-function module's timeout input. Null skips the check. Given, the module validates visibility_timeout_seconds is at least six times it, so a queue and its consumer cannot drift into duplicate processing without the plan saying so."
  type        = number
  default     = null

  validation {
    condition     = var.consumer_timeout_seconds == null || (coalesce(var.consumer_timeout_seconds, 1) >= 1 && coalesce(var.consumer_timeout_seconds, 1) <= 900)
    error_message = "consumer_timeout_seconds must be from 1 to 900, the range a Lambda timeout can take, or null to skip the visibility timeout check."
  }
}

variable "message_retention_seconds" {
  description = "How long the queue keeps a message that is never deleted, 60 to 1209600. The default of four days leaves a long weekend to notice a stuck consumer before messages start ageing out."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600 && floor(var.message_retention_seconds) == var.message_retention_seconds
    error_message = "message_retention_seconds must be a whole number from 60 to 1209600, which is 14 days."
  }
}

variable "delay_seconds" {
  description = "How long SQS holds a new message before any consumer can see it, 0 to 900. Delivery delay on the queue applies to every message; a producer can also set one per message."
  type        = number
  default     = 0

  validation {
    condition     = var.delay_seconds >= 0 && var.delay_seconds <= 900 && floor(var.delay_seconds) == var.delay_seconds
    error_message = "delay_seconds must be a whole number from 0 to 900."
  }
}

variable "max_message_size" {
  description = "Largest message the queue accepts in bytes, 1024 to 262144."
  type        = number
  default     = 262144

  validation {
    condition     = var.max_message_size >= 1024 && var.max_message_size <= 262144 && floor(var.max_message_size) == var.max_message_size
    error_message = "max_message_size must be a whole number from 1024 to 262144, which is 256 KiB."
  }
}

variable "receive_wait_time_seconds" {
  description = "Long polling wait on a ReceiveMessage call, 0 to 20. A Lambda event source mapping does its own polling and ignores this, so it only matters to a consumer calling ReceiveMessage itself, where 20 is what stops a busy loop of empty receives."
  type        = number
  default     = 20

  validation {
    condition     = var.receive_wait_time_seconds >= 0 && var.receive_wait_time_seconds <= 20 && floor(var.receive_wait_time_seconds) == var.receive_wait_time_seconds
    error_message = "receive_wait_time_seconds must be a whole number from 0 to 20."
  }
}

variable "max_receive_count" {
  description = "How many times a message may be received before the redrive policy moves it to the dead letter queue, 1 to 1000. A poison message is retried this many times and then parked, so the consumer stops replaying it forever and the message is still there to look at."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000 && floor(var.max_receive_count) == var.max_receive_count
    error_message = "max_receive_count must be a whole number from 1 to 1000."
  }
}

variable "dead_letter_queue_suffix" {
  description = "Appended to name to name the dead letter queue. On a FIFO queue the \".fifo\" suffix goes on after this one."
  type        = string
  default     = "-dlq"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,20}$", var.dead_letter_queue_suffix))
    error_message = "dead_letter_queue_suffix must be 1 to 20 characters of letters, digits, hyphens and underscores."
  }
}

variable "dead_letter_message_retention_seconds" {
  description = "How long the dead letter queue keeps a parked message, 60 to 1209600. The default of the full 14 days is deliberate: a message only lands here because something is wrong, and it is worth keeping until someone has looked at it."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dead_letter_message_retention_seconds >= 60 && var.dead_letter_message_retention_seconds <= 1209600 && floor(var.dead_letter_message_retention_seconds) == var.dead_letter_message_retention_seconds
    error_message = "dead_letter_message_retention_seconds must be a whole number from 60 to 1209600, which is 14 days."
  }
}

variable "dead_letter_visibility_timeout_seconds" {
  description = "Visibility timeout on the dead letter queue. Null follows visibility_timeout_seconds. It is not checked against consumer_timeout_seconds, because a dead letter queue is drained by hand or by a redrive rather than by the consumer."
  type        = number
  default     = null

  validation {
    condition     = var.dead_letter_visibility_timeout_seconds == null || (coalesce(var.dead_letter_visibility_timeout_seconds, 0) >= 0 && coalesce(var.dead_letter_visibility_timeout_seconds, 0) <= 43200)
    error_message = "dead_letter_visibility_timeout_seconds must be a whole number from 0 to 43200, or null to follow the main queue."
  }
}

variable "redrive_allow_policy_enabled" {
  description = "Write a redrive allow policy on the dead letter queue naming this queue as its only source. Without one any queue in the account may nominate it as a dead letter queue, so leaving this on keeps the parked messages attributable to one source."
  type        = bool
  default     = true
}

variable "kms_master_key_id" {
  description = "ARN or id of a KMS key encrypting both queues. Null leaves them on SSE-SQS, the managed encryption that is on by default and costs nothing per request. A customer key is only worth its per request cost when the message bodies need a key the account can audit and revoke separately; it also means every producer and consumer needs a grant on that key."
  type        = string
  default     = null
}

variable "kms_data_key_reuse_period_seconds" {
  description = "How long SQS reuses a data key before calling KMS again, 60 to 86400. Ignored on an SSE-SQS queue. A longer period means fewer KMS calls to pay for and a longer window in which a revoked key still decrypts."
  type        = number
  default     = 300

  validation {
    condition     = var.kms_data_key_reuse_period_seconds >= 60 && var.kms_data_key_reuse_period_seconds <= 86400 && floor(var.kms_data_key_reuse_period_seconds) == var.kms_data_key_reuse_period_seconds
    error_message = "kms_data_key_reuse_period_seconds must be a whole number from 60 to 86400, which is 24 hours."
  }
}

variable "producer_role_arns" {
  description = <<-EOT
    Role ARNs the queue policy grants sqs:SendMessage and sqs:GetQueueUrl to. Empty, the default,
    writes no queue policy at all, which leaves the queue reachable only through the identity based
    policies its principals already hold.

    This is the resource based half of the grant. A role in this account can be granted by its own
    identity policy instead; the queue policy is what makes a cross-account producer work, and what
    makes the list of producers readable from the queue.

    It does not grant kms:GenerateDataKey. A producer sending to a queue encrypted with a customer
    key needs that on the key itself, which the key's own policy owns.
  EOT

  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for arn in var.producer_role_arns :
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/.+$", arn))
    ])
    error_message = "Every producer_role_arns entry must be an IAM role or user ARN. An assumed-role session ARN is not a valid policy principal."
  }
}

variable "tags" {
  description = "Tags on both queues."
  type        = map(string)
  default     = {}
}
