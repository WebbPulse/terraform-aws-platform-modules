# terraform-aws-transaction-search

X-Ray Transaction Search for one account and region: the CloudWatch Logs resource policy that lets
X-Ray put span events, the trace segment destination that switches X-Ray to CloudWatch Logs, the
`Default` indexing rule, and an optional adoption of the reserved `aws/spans` log group so its
retention is managed rather than infinite.

This is account scoped, not application scoped. One instance per account and region.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/transaction-search`.

## Usage

```hcl
module "transaction_search" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/transaction-search"
  version = "~> 2.27"

  name_prefix = "example-staging"

  adopt_spans_log_group = var.adopt_spans_log_group
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
| `create_indexing_rule` | Manage the account's `Default` X-Ray indexing rule | `true` |
| `indexing_rule_sampling_percentage` | Percentage of traces indexed, 0 to 100 | `1` |
| `tags` | Tags on the adopted spans log group | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `resource_policy_name` | Name of the CloudWatch Logs resource policy |
| `resource_policy_document` | The resource policy JSON the module wrote |
| `spans_log_group_name` | Reserved log group spans land in, adopted or not |
| `spans_log_group_arn` | ARN of the adopted group, null when `adopt_spans_log_group` is false |
| `trace_segment_destination` | Destination X-Ray sends segments to, `CloudWatchLogs` once applied |
| `indexing_rule_name` | Name of the managed indexing rule, null when not managed |

## Gotchas

- **`adopt_spans_log_group` is a two-apply bootstrap on a fresh account, and it defaults to false.**
  `aws/spans` is reserved: `CreateLogGroup` rejects any name beginning with `aws/`, so Terraform
  cannot create it. X-Ray creates it itself the first time it writes a span to the `CloudWatchLogs`
  destination. An `import` block whose target does not exist is a plan time error, not a skipped
  import, so a brand new account applies once with this false, generates one span, then sets it
  true. Every environment that has already exported a span takes true immediately.
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
