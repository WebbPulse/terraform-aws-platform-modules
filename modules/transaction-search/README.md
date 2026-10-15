# terraform-aws-transaction-search

X-Ray Transaction Search for one account and region: the CloudWatch Logs resource policy that lets
X-Ray put span events, the trace segment destination that switches X-Ray to CloudWatch Logs, the
`Default` indexing rule, optional adoptions of the reserved `aws/spans` log group and the
`/aws/application-signals/data` log group so their retention is managed rather than infinite, and an
optional per-environment span sample ratio published for the `lambda-function` module.

This is account scoped, not application scoped. One instance per account and region.

Consumed as `terraform.webbpulse.com/WebbPulse/platform-modules/aws//modules/transaction-search`.

## Usage

```hcl
module "transaction_search" {
  source  = "terraform.webbpulse.com/WebbPulse/platform-modules/aws//modules/transaction-search"
  version = "~> 2.27"

  name_prefix = "example-staging"

  adopt_spans_log_group               = var.adopt_spans_log_group
  adopt_application_signals_log_group = var.adopt_application_signals_log_group
  span_sample_ratio                   = var.environment == "production" ? null : 0.1
}

module "api_function" {
  source = "terraform.webbpulse.com/WebbPulse/platform-modules/aws//modules/lambda-function"

  otel_environment_variables = merge(local.otel_environment, module.transaction_search.otel_environment_variables)
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name_prefix` | Prefix for the resource policy name, usually the `<product>-<environment>` prefix | required |
| `resource_policy_name_suffix` | Appended to `name_prefix` to name the resource policy | `"-transaction-search-spans"` |
| `adopt_spans_log_group` | Import the reserved `aws/spans` group and hold its retention | `false` |
| `spans_log_group_name` | Reserved log group X-Ray writes spans to | `"aws/spans"` |
| `spans_log_group_retention_in_days` | Retention held on the adopted group | `7` |
| `application_signals_log_group_name` | Second group named in the policy; null leaves it out | `"/aws/application-signals/data"` |
| `adopt_application_signals_log_group` | Import `/aws/application-signals/data` and hold its retention | `false` |
| `application_signals_log_group_retention_in_days` | Retention held on the adopted Application Signals group | `30` |
| `span_sample_ratio` | Trace fraction, 0 to 1, published as `WEBBPULSE_OTEL_SAMPLE_RATIO`; null publishes nothing | `null` |
| `create_indexing_rule` | Manage the account's `Default` X-Ray indexing rule | `true` |
| `indexing_rule_sampling_percentage` | Percentage of traces indexed, 0 to 100 | `1` |
| `tags` | Tags on the adopted spans and Application Signals log groups | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `resource_policy_name` | Name of the CloudWatch Logs resource policy |
| `resource_policy_document` | The resource policy JSON the module wrote |
| `spans_log_group_name` | Reserved log group spans land in, adopted or not |
| `spans_log_group_arn` | ARN of the adopted group, null when `adopt_spans_log_group` is false |
| `trace_segment_destination` | Destination X-Ray sends segments to, `CloudWatchLogs` once applied |
| `indexing_rule_name` | Name of the managed indexing rule, null when not managed |
| `application_signals_log_group_arn` | ARN of the adopted Application Signals group, null when not adopted |
| `otel_environment_variables` | `{ WEBBPULSE_OTEL_SAMPLE_RATIO = "<ratio>" }`, or `{}` when `span_sample_ratio` is null |

## Gotchas

- **`adopt_spans_log_group` is a two-apply bootstrap on a fresh account, and it defaults to false.**
  `aws/spans` is reserved: `CreateLogGroup` rejects any name beginning with `aws/`, so Terraform
  cannot create it. X-Ray creates it itself the first time it writes a span to the `CloudWatchLogs`
  destination. An `import` block whose target does not exist is a plan time error, not a skipped
  import, so a brand new account applies once with this false, generates one span, then sets it
  true. Every environment that has already exported a span takes true immediately.
- **The `import` block lives in the consumer's root module, not here.** Terraform only allows
  `import` blocks in the root module, so this one cannot ship inside the module. The module
  declares the `aws_cloudwatch_log_group.spans` resource, and a consumer that sets
  `adopt_spans_log_group = true` must also write the matching import against the module's address:

  ```hcl
  import {
    for_each = var.adopt_spans_log_group ? toset(["aws/spans"]) : toset([])

    to = module.transaction_search.aws_cloudwatch_log_group.spans[each.key]
    id = each.value
  }
  ```

  Without it, an apply with `adopt_spans_log_group = true` tries to *create* `aws/spans` and fails
  with an `InvalidParameterException` naming the reserved prefix. The `for_each` has to be gated on
  the same variable the module gets, or the import fires on an account where the group does not
  exist yet and fails at plan time.
- **`adopt_application_signals_log_group` follows the same pattern and needs its own import.**
  X-Ray writes Application Signals data derived from spans into `/aws/application-signals/data`,
  which AWS creates with no retention. The module holds it at
  `application_signals_log_group_retention_in_days` (30 by default) once adopted, and the consumer
  writes a second import gated on the same variable:

  ```hcl
  import {
    for_each = var.adopt_application_signals_log_group ? toset(["/aws/application-signals/data"]) : toset([])

    to = module.transaction_search.aws_cloudwatch_log_group.application_signals[each.key]
    id = each.value
  }
  ```

  Check the group exists first (`aws logs describe-log-groups --log-group-name-prefix
  /aws/application-signals/data`); importing a missing group is a plan time error. Unlike `aws/spans`
  the name is not reserved, so a consumer could let Terraform create it on a fresh account instead,
  but it then races AWS for the name, so prefer the two-apply bootstrap. Destroying the module with
  the group adopted deletes the group and its data.
- **`span_sample_ratio` is the lever that cuts ingestion; the indexing rule and X-Ray sampling rules
  are not.** Transaction Search ingests every span X-Ray receives into `aws/spans` and
  `/aws/application-signals/data`; `indexing_rule_sampling_percentage` only chooses how many of those
  become indexed trace summaries. X-Ray sampling rules (`aws_xray_sampling_rule`) apply only to SDKs
  that poll for centralized sampling, and the webbpulse SDK does not: it runs its own tail sampler
  reading `WEBBPULSE_OTEL_SAMPLE_RATIO`, always keeping traces with an error. Lambda's own Active
  tracing segments sample at a fixed 1 request per second plus 5 percent that Lambda does not let
  you configure; the only way to drop those is `tracing_mode = "PassThrough"` on the function. The
  module only publishes the variable: it reaches a function when the consumer merges
  `otel_environment_variables` into the `lambda-function` input, and a key there overrides the same
  key set by hand in `environment_variables`.
- Without the adoption the group still exists and still collects spans; it just keeps the default
  never-expire retention and bills for it. Adopting it is the only reason this input exists.
- The resource policy has to exist before the trace segment destination is switched, or X-Ray
  accepts the destination and then silently fails every `PutLogEvents`. The `depends_on` chain
  inside the module orders the policy, then the destination, then the group and the indexing rule.
- `create_indexing_rule` manages a rule that exists whether or not Terraform knows about it. There
  is exactly one rule named `Default` per account and region, so this is an adoption of a
  pre-existing object rather than a create; two module instances in one account and region fight
  over it. The 1 percent default is the free tier's, and indexed spans are billed.
- Needs aws provider >= 6.46 for `aws_xray_trace_segment_destination` and `aws_xray_indexing_rule`.
  The module's own `versions.tf` pins that floor, which is higher than the rest of the repository's.
- **Adopting this module from a hand-written `transaction_search.tf` needs `moved` blocks**, because
  every resource changes address. The resource names inside the module are `spans`, `this` and
  `default` where the originals were `transaction_search_spans`, `main` and `default`:

  ```hcl
  moved {
    from = aws_cloudwatch_log_resource_policy.transaction_search_spans
    to   = module.transaction_search.aws_cloudwatch_log_resource_policy.spans
  }

  moved {
    from = aws_xray_trace_segment_destination.main
    to   = module.transaction_search.aws_xray_trace_segment_destination.this
  }

  moved {
    from = aws_xray_indexing_rule.default
    to   = module.transaction_search.aws_xray_indexing_rule.default[0]
  }

  moved {
    from = aws_cloudwatch_log_group.spans["aws/spans"]
    to   = module.transaction_search.aws_cloudwatch_log_group.spans["aws/spans"]
  }
  ```

  The indexing rule gains a `[0]` index because `create_indexing_rule` makes it a counted resource.
  The spans group keeps its `["aws/spans"]` key. Drop the last `moved` block in a product that
  never adopted the group, and drop the module's `adopt_spans_log_group` with it.
- The module derives the account, region and partition from the provider rather than taking them as
  inputs, so the ARNs it writes follow whichever provider alias the module is instantiated with.
  The hand-written originals hardcoded the `aws` partition; this one does not, which changes no
  plan in a commercial account.
