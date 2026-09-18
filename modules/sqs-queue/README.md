# terraform-aws-sqs-queue

A queue and the dead letter queue behind it: a redrive policy with a max receive count, SSE-SQS by
default or a KMS key when one is given, optional FIFO, a redrive allow policy naming this queue as
the dead letter queue's only source, and an optional queue policy granting a list of producer roles
`sqs:SendMessage`.

Built to be consumed by `modules/lambda-function`'s `sqs_event_sources`, which takes `queue_arn`
from here.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/sqs-queue`.

## Usage

```hcl
module "jobs_queue" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/sqs-queue"
  version = "~> 2.24"

  name = "example-staging-jobs"

  consumer_timeout_seconds   = 30
  visibility_timeout_seconds = 180
  max_receive_count          = 5

  producer_role_arns = [module.api_lambda.role_arn]
}

module "worker_lambda" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function"
  version = "~> 2.24"

  function_name = "example-staging-worker"
  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  timeout       = 30

  code = {
    filename         = data.archive_file.placeholder.output_path
    source_code_hash = data.archive_file.placeholder.output_base64sha256
  }

  sqs_event_sources = {
    jobs = {
      queue_arn = module.jobs_queue.queue_arn
    }
  }
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | Queue name without a `.fifo` suffix; the module appends one on a FIFO queue | required |
| `fifo_queue` | Make this a FIFO queue; the type cannot be changed after the create | `false` |
| `content_based_deduplication` | Derive a FIFO deduplication id from the body; FIFO only | `false` |
| `deduplication_scope` | `messageGroup` or `queue`, or null for the service default; FIFO only | `null` |
| `fifo_throughput_limit` | `perMessageGroupId` or `perQueue`, or null for the service default; FIFO only | `null` |
| `visibility_timeout_seconds` | Invisibility after one receive, 0 to 43200 | `180` |
| `consumer_timeout_seconds` | Consuming Lambda's timeout; enables the six-times check, null skips it | `null` |
| `message_retention_seconds` | How long an undeleted message is kept, 60 to 1209600 | `345600` |
| `delay_seconds` | Delivery delay on every message, 0 to 900 | `0` |
| `max_message_size` | Largest accepted message in bytes, 1024 to 262144 | `262144` |
| `receive_wait_time_seconds` | Long polling wait, 0 to 20; ignored by an event source mapping | `20` |
| `max_receive_count` | Receives before the redrive policy parks a message, 1 to 1000 | `5` |
| `dead_letter_queue_suffix` | Appended to `name` to name the dead letter queue | `"-dlq"` |
| `dead_letter_message_retention_seconds` | How long a parked message is kept, 60 to 1209600 | `1209600` |
| `dead_letter_visibility_timeout_seconds` | Dead letter visibility timeout, null follows the main queue | `null` |
| `redrive_allow_policy_enabled` | Write a redrive allow policy naming this queue as the only source | `true` |
| `kms_master_key_id` | KMS key encrypting both queues; null leaves them on SSE-SQS | `null` |
| `kms_data_key_reuse_period_seconds` | Data key reuse window, 60 to 86400; ignored on SSE-SQS | `300` |
| `producer_role_arns` | Role ARNs the queue policy grants `sqs:SendMessage` and `sqs:GetQueueUrl` | `[]` |
| `tags` | Tags on both queues | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `queue_arn` | Queue ARN, which is what lambda-function's `sqs_event_sources` takes as `queue_arn` |
| `queue_url` | Queue URL, which is what every SQS API call takes rather than the ARN |
| `queue_name` | Queue name with the `.fifo` suffix on a FIFO queue; the CloudWatch `QueueName` dimension |
| `queue_id` | Queue id, which for SQS is its URL |
| `dead_letter_queue_arn` | Dead letter queue ARN |
| `dead_letter_queue_url` | Dead letter queue URL, for a redrive or for draining it by hand |
| `dead_letter_queue_name` | Dead letter queue name; the CloudWatch `QueueName` dimension for its alarm |
| `kms_master_key_id` | Key encrypting both queues, null on an SSE-SQS queue |
| `queue_policy_json` | Producer grant, null when no producer was named |

## Gotchas

- **The visibility timeout must be at least six times the consumer's own timeout.** That is the
  rule Lambda documents for an SQS event source, and it is why `consumer_timeout_seconds` exists:
  pass the consuming function's `timeout` and the plan fails rather than the queue silently handing
  the same message to a second invocation while the first is still working on it. The check is a
  `precondition` on the queue, so it fires at plan time and names both numbers. Leave
  `consumer_timeout_seconds` null for a queue with no Lambda consumer.
- **The consumer needs a route to receive the batch on.** A Lambda consuming this queue through
  `modules/lambda-function`'s `sqs_event_sources` runs the Web Adapter, which posts a non-HTTP
  invocation to `events_path`, `/events` by default. The application has to mount that route.
  Wiring the mapping to a package that does not serve the path makes the adapter post a batch to a
  404, and the mapping then retries it until this queue's `max_receive_count` parks it in the dead
  letter queue. The same input reaches the function as both `AWS_LWA_PASS_THROUGH_PATH` and
  `APP_EVENTS_PATH` so the adapter's path and the application's cannot drift apart.
- A queue and the function polling it must be in the same region. An event source mapping is
  regional and `CreateEventSourceMapping` rejects a cross-region ARN, which lambda-function checks
  against the provider's own region at plan time.
- `sqs_managed_sse_enabled` and `kms_master_key_id` conflict in the provider even when one of them
  is null, so the module leaves the managed setting out entirely rather than setting it false when
  a key is given.
- A customer key means every producer needs `kms:GenerateDataKey` and every consumer needs
  `kms:Decrypt` on that key, granted by the key's own policy. `producer_role_arns` writes the queue
  policy only; it does not touch the key. SSE-SQS is the default because it costs nothing per
  request and needs no grant at all.
- The dead letter queue takes its `message_retention_seconds` from its own input and keeps the full
  fourteen days by default. A message only lands there because something is wrong, and the point of
  the queue is that it is still there when someone looks.
- `redrive_allow_policy_enabled` is on by default so no other queue in the account can nominate this
  dead letter queue. Turn it off to share one dead letter queue across several sources, and write
  the allow policy yourself with every source listed.
- Renaming the queue replaces it, which discards every message still in it. The `.fifo` suffix is
  appended by the module, so passing a name that already ends in `.fifo` produces `.fifo.fifo`;
  `name` rejects the dot outright.
- FIFO is not reversible. A standard queue cannot be converted, so the fix is a new queue and a
  migration of the producers.
