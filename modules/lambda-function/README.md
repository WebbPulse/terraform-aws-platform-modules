# terraform-aws-lambda-function

Creates a Lambda function with its IAM execution role and its CloudWatch log group, seeded with a
placeholder package whose code attributes are then ignored so a deployment pipeline owns the code.
The package is a zip by default and can be a container image instead.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function`.

## Usage

```hcl
module "lambda_api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function"
  version = "~> 1.6"

  function_name = "example-production-api"
  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  memory_size   = 1024
  timeout       = 29

  code = {
    filename         = data.archive_file.lambda_placeholder.output_path
    source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256
  }

  environment_variables = local.lambda_environment
  log_retention_days    = 14
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `function_name` | Function name as-is, not a prefix; changing it replaces the function | required |
| `code` | Where the seed package comes from; see the shape below | required |
| `role_name` | Execution role name, null for `<function_name>-role` | `null` |
| `role_path` | IAM path of the execution role; changing it replaces the role | `"/"` |
| `role_description` | Description on the execution role, null for none | `null` |
| `permissions_boundary_arn` | Permissions boundary policy ARN on the execution role | `null` |
| `assume_role_service_principals` | Service principals allowed to assume the execution role | `["lambda.amazonaws.com"]` |
| `role_tags` | Extra tags on the execution role only | `{}` |
| `package_type` | `Zip` or `Image` | `"Zip"` |
| `runtime` | Managed runtime identifier, for example `python3.13`; required for `Zip`, null for `Image` | `null` |
| `handler` | Entry point in the package; required for `Zip`, null for `Image` | `null` |
| `image_config` | Overrides for the image's `ENTRYPOINT`, `CMD` and `WORKDIR`; null keeps the image's own | `null` |
| `architectures` | Exactly one of `["x86_64"]` or `["arm64"]` | `["x86_64"]` |
| `memory_size` | Memory in MB, 128 to 10240, which also sets the CPU share | `128` |
| `timeout` | Run time in seconds, 1 to 900; 29 or less behind an HTTP API | `3` |
| `description` | Description on the function, null for none | `null` |
| `publish` | Publish a numbered version on every code or configuration change | `false` |
| `reserved_concurrent_executions` | Reserved concurrency; null or `-1` for no reservation | `null` |
| `tracing_mode` | `Active`, `PassThrough`, or null to omit the tracing block | `"Active"` |
| `attach_xray_write_policy` | Attach the inline X-Ray write policy when tracing is `Active` | `true` |
| `environment_variables` | Environment variables; an empty map omits the environment block | `{}` |
| `otel_environment_variables` | Tracing and Web Adapter variables, merged over `environment_variables` | `{}` |
| `layers` | Layer ARNs to attach in order, at most 5 | `[]` |
| `log_group_name` | Log group name, null for `/aws/lambda/<function_name>` | `null` |
| `log_retention_days` | Retention in days, a value CloudWatch Logs accepts; 0 never expires | `14` |
| `log_group_kms_key_id` | KMS key ARN for the log group; null uses the service key | `null` |
| `log_group_tags` | Extra tags on the log group only | `{}` |
| `log_format` | Format for Lambda's platform logs, `JSON` or `Text` | `"JSON"` |
| `application_log_level` | Minimum application log level; only meaningful with `JSON` | `null` |
| `system_log_level` | Minimum platform log level; only meaningful with `JSON` | `null` |
| `set_logging_config_log_group` | Name the log group explicitly inside `logging_config` | `false` |
| `vpc_config` | `{ subnet_ids, security_group_ids }`; null keeps the function outside a VPC | `null` |
| `ephemeral_storage_size` | Size of `/tmp` in MB, 512 to 10240; null leaves the block out, which is 512 | `null` |
| `sqs_event_sources` | SQS queues this function polls, as a map; see the shape below | `{}` |
| `dynamodb_stream_event_sources` | DynamoDB table streams this function reads, as a map; see the shape below | `{}` |
| `attach_role_policies` | Attach the source read policies the two event source maps need to the execution role | `true` |
| `events_path` | Path the Web Adapter posts a non-HTTP invocation to, emitted only with an event source | `"/events"` |
| `tags` | Extra tags on the function only | `{}` |

Each `sqs_event_sources` entry takes `queue_arn` (required), and optionally `kms_key_arn`,
`batch_size` (`10`), `maximum_batching_window_seconds` (`5`), `function_response_types`
(`["ReportBatchItemFailures"]`), `filter_criteria` (`[]`), `maximum_concurrency` (`null`) and
`enabled` (`true`). The map key names the mapping in state, so renaming it destroys one mapping and
creates another.

Each `dynamodb_stream_event_sources` entry takes `stream_arn` (required), and optionally
`batch_size` (`100`), `starting_position` (`"LATEST"`), `maximum_batching_window_in_seconds` (`0`),
`filter_patterns` (`[]`), `bisect_batch_on_function_error` (`true`), `maximum_retry_attempts`
(`null`), `on_failure_destination_arn` (`null`) and `enabled` (`true`). `stream_arn` is the table's
`stream_arn`, usually `module.tables.stream_arns["issues"]`, not the table ARN. `filter_patterns`
holds already encoded JSON strings, so `jsonencode({ eventName = ["INSERT", "MODIFY"] })` is one
entry. The map key names the mapping in state, so renaming it destroys one mapping and creates
another, and the replacement starts from `starting_position` rather than where the old one stopped.

```hcl
dynamodb_stream_event_sources = {
  issues = {
    stream_arn                 = module.tables.stream_arns["issues"]
    starting_position          = "LATEST"
    filter_patterns            = [jsonencode({ eventName = ["INSERT", "MODIFY"] })]
    maximum_retry_attempts     = 3
    on_failure_destination_arn = module.stream_failures.queue_arn
  }
}
```

`code` takes exactly one of three shapes: `{ filename, source_code_hash }` for a local zip,
`{ s3_bucket, s3_key, s3_object_version, source_code_hash }` for an object in S3, or
`{ image_uri }` for a container image, which also needs `package_type = "Image"`.

## Outputs

| Name | Description |
| --- | --- |
| `function_name` | Function name, for an invoke permission, an alarm dimension or a deploy pipeline |
| `function_arn` | Function ARN, without a version qualifier |
| `invoke_arn` | Invoke ARN for an API Gateway `AWS_PROXY` integration, such as http-api's `lambda_invoke_arn` |
| `qualified_arn` | ARN of the most recently published version, empty unless `publish` is on |
| `qualified_invoke_arn` | Invoke ARN of the most recently published version, empty unless `publish` is on |
| `version` | Latest published version, `$LATEST` unless `publish` is on |
| `role_name` | Execution role name, for an `aws_iam_role_policy_attachment` outside the module |
| `role_id` | Execution role id, which is what `aws_iam_role_policy` takes as its `role` argument |
| `role_arn` | Execution role ARN, for a policy naming the role as a principal |
| `role_unique_id` | Stable unique id of the execution role, usable in an `aws:userId` condition |
| `log_group_name` | Name of the function's CloudWatch log group |
| `log_group_arn` | Log group ARN; a logs policy appends `:*` to it |
| `package_type` | `Zip` or `Image`, echoing the input |
| `image_uri` | Seed image the function was created with, empty for a `Zip` function |
| `xray_write_policy_attached` | Whether the module attached its inline X-Ray write policy |
| `sqs_event_source_mapping_uuids` | UUID of each SQS event source mapping, keyed as `sqs_event_sources` was |
| `sqs_event_source_policy_json` | Queue read policy per entry, for a consumer attaching it elsewhere |
| `dynamodb_stream_event_source_mapping_uuids` | UUID of each stream event source mapping, keyed as `dynamodb_stream_event_sources` was |
| `dynamodb_stream_event_source_policy_json` | Stream read policy per entry, for a consumer attaching it elsewhere |
| `events_path` | Path the Web Adapter posts a batch to, null when no event source is wired |

## Gotchas

- The module creates the execution role but grants it nothing. Attach application permissions
  yourself with `aws_iam_role_policy` against `role_id`, or the function can reach no AWS API.
- Active tracing without X-Ray write permission fails silently: the segment publish is denied and
  the traces are simply absent. Leave `attach_xray_write_policy` on unless the application already
  grants `xray:PutTraceSegments` and `xray:PutTelemetryRecords` itself.
- The `aws/spans` log group X-Ray Transaction Search writes to is reserved, so Terraform cannot
  pre-create it. Let X-Ray create it and import it to set retention. Needs aws provider >= 6.46.
- `filename`, `source_code_hash`, `s3_bucket`, `s3_key`, `s3_object_version` and `image_uri` are all
  under `lifecycle` `ignore_changes`, so `code` is only a seed. The list is fixed because Terraform
  requires `ignore_changes` to be static, so it cannot be driven by a variable.
- An Image function and its ECR repository must be in the same region, and Lambda pulls as the
  service rather than as the execution role, so a cross-account grant goes in the repository policy
  naming `lambda.amazonaws.com`.
- Seed `code.image_uri` with a digest, not a tag. A tag can be repointed underneath a running
  function, and the digest is what makes the deploy recorded in state mean anything.
- With keep-last-10 lifecycle rules a pinned bootstrap image tag can expire from ECR. The plan stays
  green and the apply fails, so refresh the bootstrap tag to the current head sha before an apply
  that replaces functions.
- `set_logging_config_log_group` points at the same group either way, but flipping it is an in place
  update of the function, so match what the application already has in state.
- **An event source needs a route to post the batch to.** A non-empty `sqs_event_sources` or
  `dynamodb_stream_event_sources` sets `AWS_LWA_PASS_THROUGH_PATH` and `APP_EVENTS_PATH` to
  `events_path`, `/events` by default, so the Web Adapter posts a non-HTTP invocation there and the
  FastAPI app mounts the same route. One input feeds both, so they cannot drift, and two source kinds
  on one function share one route. Wiring a source to a package that does not serve the path makes
  the adapter post to a 404 and the mapping retries the batch until the queue's redrive policy parks
  it or the stream record expires. Both variables are emitted only when at least one source is wired,
  and `otel_environment_variables` still wins over them.
- The queue and the function must be in the same region. An event source mapping is regional and
  `CreateEventSourceMapping` rejects a cross-region ARN, so the module checks each queue ARN's region
  against the provider's at plan time rather than letting the apply fail.
- `attach_role_policies` cannot be false while `sqs_event_sources` is non-empty.
  `CreateEventSourceMapping` checks the function role can read the queue during the create call, and
  the mapping is created here, so it can only be ordered behind a grant created here too. Attach the
  `sqs_event_source_policy_json` outputs by hand and build the mappings yourself if the grants have
  to live elsewhere.
- Leave `function_response_types` on its `["ReportBatchItemFailures"]` default and have the handler
  return the failed message ids. Without it one failed message replays the whole batch, so every
  message that already succeeded is delivered and processed again.
- Set `maximum_concurrency` on a queue that can burst. Without it the mapping scales up against the
  account's unreserved concurrency, so one busy queue can starve every other function in the account.
- A `batch_size` above 10 requires `maximum_batching_window_seconds` of at least 1. That is the
  service's rule, and the module validates it so the failure lands at plan rather than on the create
  call.
- **A `dynamodb_stream_event_sources` entry takes the table's stream ARN, not its table ARN.** A
  stream ARN ends in `/stream/<label>`, the label changes whenever the stream is turned off and on
  again, and `stream_arn` on a table is null until `stream_view_type` is set, so the module rejects a
  table ARN at plan time rather than letting `CreateEventSourceMapping` reject it on the create call.
- A DynamoDB stream mapping reads each shard in order, so one failing batch blocks its shard until
  the batch succeeds or the record ages out of the 24 hour retention window. `maximum_retry_attempts`
  caps the retries, `bisect_batch_on_function_error` stops one poisoned record failing the whole
  batch forever, and `on_failure_destination_arn` is the only place the discarded batch's metadata is
  recorded. Set all three on a stream that matters; the defaults bisect and retry until expiry.
- `starting_position` defaults to `LATEST`, so wiring a stream to a table that already has data
  processes only changes from the apply onwards. `TRIM_HORIZON` replays the retention window instead,
  which on a busy table is a burst of invocations against a handler that has never seen them.
- `filter_patterns` holds already encoded JSON strings, unlike `sqs_event_sources`' `filter_criteria`
  which takes objects and encodes them for you. The two shapes differ because a stream filter is
  usually a literal `eventName` pattern that reads better written out once.
- `attach_role_policies` cannot be false while `dynamodb_stream_event_sources` is non-empty, for the
  same reason it cannot be false with a queue wired: `CreateEventSourceMapping` checks the function
  role can read the stream during the create call, and the mapping is created here. Attach the
  `dynamodb_stream_event_source_policy_json` outputs by hand and build the mappings yourself if the
  grants have to live elsewhere.
- Terraform cannot express a `depends_on` from inside a module to a resource in the caller. Put the
  `depends_on` on the module block instead when a greenfield apply needs the ordering.
