# terraform-aws-app-baseline

The account level housekeeping every WebbPulse application stack carries: a tag based resource
group that collects the project's resources into one console view, Cost Explorer anomaly
detection, and the free budget alerts. None of it serves traffic, all of it is the same shape in
every account, and it was duplicated by hand in `terraform/management.tf` in both estates.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline`. The module
reproduces the existing resources exactly, so adopting it is five `moved` blocks and an empty
plan. See [Adoption](#adoption).

## How it works

```
module "app_baseline"  name = "<project>-<environment>"
  │
  ├─ aws_resourcegroups_group.this[0]            name = <name>
  │    resource_query = { ResourceTypeFilters, TagFilters }   built from
  │                     resource_group_resource_type_filters + resource_group_tag_filters
  │
  ├─ aws_ce_anomaly_monitor.this[0]              name = <name>, DIMENSIONAL on SERVICE
  │    └─ aws_ce_anomaly_subscription.this[0]    name = <name>, frequency
  │         subscriber  EMAIL  per notification_emails, then SNS per anomaly_sns_topic_arns
  │         threshold_expression  ANOMALY_TOTAL_IMPACT_ABSOLUTE >= anomaly_threshold
  │
  └─ aws_budgets_budget.this[<suffix>]           name = "<name>-<suffix>"   one per budgets entry
       notification  per thresholds entry, every one addressed to notification_emails
```

- **Resource group.** A `TAG_FILTERS_1_0` query, which is what `aws_resourcegroups_group` writes
  when given a query with `ResourceTypeFilters` and `TagFilters`. The filters are a map of tag key
  to accepted values, so the common case is one line. Note that the group should almost always
  filter on the bare project tag rather than on `name`: `name` is `<project>-<environment>` and no
  resource carries that as its `Project` tag.
- **Anomaly detection.** One `DIMENSIONAL` monitor on `SERVICE`, so AWS learns a spend baseline
  per service and reports departures from it, plus one subscription that decides who hears about
  it. The threshold is total absolute dollar impact: below it, an anomaly is detected and shown in
  the console but no mail is sent. Anomaly detection costs nothing.
- **Budgets.** A map keyed by the suffix appended to `name`, so the two budgets both estates carry
  are two lines. `limit_amount` is a string because that is how AWS Budgets stores it, and passing
  the stored string through unchanged is what keeps an adopted budget from planning a change.
  The first two budgets in an account are free; each one after that is billed per day.
- **Tagging.** Only the resource group takes tags. Cost Explorer anomaly monitors, anomaly
  subscriptions and budgets have no usable tag surface, which is why the estates tag them through
  provider `default_tags` and read back an empty tag map.

Each of the three parts is independently gated, so an account that gets its resource group or its
anomaly monitoring from somewhere else consumes the module for the rest.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | Base name: the group, monitor and subscription take it verbatim, budgets append their suffix | required |
| `notification_emails` | Addresses on the anomaly subscription and every budget notification, in order | `[]` |
| `resource_group_enabled` | Create the resource group | `true` |
| `resource_group_description` | Description on the group; `null` leaves it unset | `null` |
| `resource_group_tag_filters` | Tag key to accepted values, rendered into `TagFilters` | `{}` |
| `resource_group_resource_type_filters` | `ResourceTypeFilters` in the query | `["AWS::AllSupported"]` |
| `anomaly_detection_enabled` | Create the anomaly monitor and subscription | `true` |
| `anomaly_monitor_dimension` | `SERVICE` or `LINKED_ACCOUNT` | `SERVICE` |
| `anomaly_threshold` | Dollars of total absolute impact at or above which an anomaly is mailed | `10` |
| `anomaly_frequency` | `DAILY`, `WEEKLY` or `IMMEDIATE`; `IMMEDIATE` needs an SNS subscriber | `DAILY` |
| `anomaly_sns_topic_arns` | SNS topics added to the subscription alongside the emails | `[]` |
| `budgets` | Suffix to `{ limit_amount, limit_unit?, time_unit?, budget_type?, thresholds? }` | `{}` |
| `budget_sns_topic_arns` | SNS topics added to every budget notification | `[]` |
| `tags` | Extra tags on the resource group, on top of `default_tags` | `{}` |

A `budgets` entry's `thresholds` is a list of
`{ threshold, comparison_operator?, threshold_type?, notification_type? }` and defaults to
`[{ threshold = 100 }]`, which is a `GREATER_THAN` `PERCENTAGE` `ACTUAL` alert at 100 percent of
the limit. That is the notification block both estates have today.

## Outputs

| Name | Description |
| --- | --- |
| `resource_group_arn` | ARN of the group, `null` when disabled |
| `resource_group_name` | Name of the group, which is also its id |
| `anomaly_monitor_arn` | ARN of the monitor; pass it to a second subscription for another audience |
| `anomaly_subscription_arn` | ARN of the subscription |
| `budget_names` | Budget key to the full stored name, for example `{ "monthly-warn" = "carmodpicker-production-monthly-warn" }` |
| `budget_arns` | Budget key to ARN |

## Rendering guarantees

The resource group's query is a JSON document, so it has to come out byte identical or the group
plans a change. `jsonencode()` sorts keys, and the module emits exactly the two fields the estates
emit, `ResourceTypeFilters` and `TagFilters`, with `TagFilters` a list of `{ Key, Values }`. A
single tag key therefore renders the same document that is in state today.

`anomaly_threshold` is a number on the module's surface and a string in the API. It is formatted
with `%g`, so `10` renders as `"10"` rather than `"10.0"`, which is the value both estates stored.
A threshold that genuinely has cents, `12.5`, renders as `"12.5"`.

`limit_amount` is deliberately a string and is passed through untouched. AWS Budgets stores the
limit as a decimal string and the provider compares it as one, so `"30"` and `"30.0"` are
different stored values even though they are the same number. Copy the string out of state.

`tags = {}` is passed to the resource group as `null`, which is the same as omitting the argument,
so an adopted group carries `default_tags` only and plans no tag change. Empty
`anomaly_sns_topic_arns`, `budget_sns_topic_arns` and `notification_emails` lists are empty sets
on the wire, indistinguishable from an unset argument.

## Adoption

Both estates follow the same recipe. Replace the contents of `terraform/management.tf` with the
module block and the `moved` blocks below. Nothing outside that file referenced these resources in
either estate, so no output or reference has to be repointed. Land it on `staging` first and read
the speculative plan: it must show only the moves, `0 to add, 0 to change, 0 to destroy`.

The module ships from 1.6.0, so consumers need `version = "~> 1.6"`.

Two things to keep exactly as they are. The tag filter matches `local.project`, not `local.prefix`
(the group collects the project across environments, and no resource is tagged with the prefix),
and the budget suffixes are `monthly-warn` and `monthly-critical`, because the stored budget names
are `<prefix>-monthly-warn` and `<prefix>-monthly-critical`.

### CarModPicker

```hcl
module "app_baseline" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline"
  version = "~> 1.6"

  name                = local.prefix
  notification_emails = ["tyler@webbpulse.com", "tylert2610@gmail.com"]

  resource_group_description = "All CarModPicker managed resources"
  resource_group_tag_filters = {
    Project = [local.project]
  }

  budgets = {
    "monthly-warn"     = { limit_amount = "30" }
    "monthly-critical" = { limit_amount = "60" }
  }
}

moved {
  from = aws_resourcegroups_group.carmodpicker
  to   = module.app_baseline.aws_resourcegroups_group.this[0]
}

moved {
  from = aws_ce_anomaly_monitor.carmodpicker
  to   = module.app_baseline.aws_ce_anomaly_monitor.this[0]
}

moved {
  from = aws_ce_anomaly_subscription.carmodpicker
  to   = module.app_baseline.aws_ce_anomaly_subscription.this[0]
}

moved {
  from = aws_budgets_budget.warn
  to   = module.app_baseline.aws_budgets_budget.this["monthly-warn"]
}

moved {
  from = aws_budgets_budget.critical
  to   = module.app_baseline.aws_budgets_budget.this["monthly-critical"]
}
```

### WebbPulse-Portfolio

Identical but for the description and the two limits, and the old resources are named
`webbpulse` rather than `carmodpicker`.

```hcl
module "app_baseline" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline"
  version = "~> 1.6"

  name                = local.prefix
  notification_emails = ["tyler@webbpulse.com", "tylert2610@gmail.com"]

  resource_group_description = "All WebbPulse managed resources"
  resource_group_tag_filters = {
    Project = [local.project]
  }

  budgets = {
    "monthly-warn"     = { limit_amount = "10" }
    "monthly-critical" = { limit_amount = "25" }
  }
}

moved {
  from = aws_resourcegroups_group.webbpulse
  to   = module.app_baseline.aws_resourcegroups_group.this[0]
}

moved {
  from = aws_ce_anomaly_monitor.webbpulse
  to   = module.app_baseline.aws_ce_anomaly_monitor.this[0]
}

moved {
  from = aws_ce_anomaly_subscription.webbpulse
  to   = module.app_baseline.aws_ce_anomaly_subscription.this[0]
}

moved {
  from = aws_budgets_budget.warn
  to   = module.app_baseline.aws_budgets_budget.this["monthly-warn"]
}

moved {
  from = aws_budgets_budget.critical
  to   = module.app_baseline.aws_budgets_budget.this["monthly-critical"]
}
```

### What the module reproduces, attribute by attribute

| Attribute | Today | Module |
| --- | --- | --- |
| Group `name` | `local.prefix` | `name` |
| Group `description` | `All <Project> managed resources` | `resource_group_description` |
| Group `resource_query.query` | `AWS::AllSupported` plus one `Project` tag filter | same document from the two filter variables |
| Group `tags` | none beyond `default_tags` | `tags = {}` becomes `null` |
| Monitor `name`, `monitor_type`, `monitor_dimension` | `local.prefix`, `DIMENSIONAL`, `SERVICE` | `name` and the two defaults |
| Subscription `name`, `frequency`, `monitor_arn_list` | `local.prefix`, `DAILY`, the monitor | `name`, default frequency, the monitor |
| Subscription `subscriber` blocks | two `EMAIL` blocks in a fixed order | one per `notification_emails`, same order |
| Subscription `threshold_expression` | `ANOMALY_TOTAL_IMPACT_ABSOLUTE >= "10"` | same, from `anomaly_threshold` |
| Budget `name` | `${local.prefix}-monthly-warn` and `-monthly-critical` | `"${name}-${key}"` |
| Budget `budget_type`, `limit_unit`, `time_unit` | `COST`, `USD`, `MONTHLY` | the three defaults |
| Budget `limit_amount` | `"30"`/`"60"`, `"10"`/`"25"` | the string passed through |
| Budget `notification` | one `GREATER_THAN` `ACTUAL` `PERCENTAGE` block at 100 with both emails | the default `thresholds` entry |

## Known limits

- Cost budgets only in practice. `budget_type` accepts the usage and reservation types, but the
  module has no `cost_filter` or `cost_types` surface, so a budget that has to scope itself to one
  service or exclude credits is still written by hand.
- One anomaly monitor, and it is `DIMENSIONAL`. A `CUSTOM` monitor over a cost category or a
  specific set of accounts is a different resource; point a second subscription at
  `anomaly_monitor_arn` if the same monitor needs a second audience with a different threshold.
- Budget notifications all address the same subscribers. A warn budget that mails one list and a
  critical budget that pages another needs two module instances, or the second budget written
  outside the module.
- Nothing here is regional, but the resource group is: it lives in the provider's region and
  surfaces that region's resources. The Cost Explorer and Budgets resources are global regardless
  of which provider they are created through.
