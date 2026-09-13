# terraform-aws-app-baseline

The account level housekeeping an application stack carries: a tag based resource group, Cost
Explorer anomaly detection, and cost budgets with email or SNS alerts. Each of the three parts is
independently gated, so an account that gets one of them elsewhere consumes the module for the rest.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline`.

## Usage

```hcl
module "app_baseline" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline"
  version = "~> 1.6"

  name                = local.prefix
  notification_emails = ["alerts@example.com"]

  resource_group_description = "All Example managed resources"
  resource_group_tag_filters = {
    Project = [local.project]
  }

  budgets = {
    "monthly-warn"     = { limit_amount = "30" }
    "monthly-critical" = { limit_amount = "60" }
  }
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | Base name: group, monitor and subscription take it verbatim, budgets append their suffix | required |
| `notification_emails` | Addresses on the anomaly subscription and every budget notification, in order | `[]` |
| `resource_group_enabled` | Create the tag based resource group | `true` |
| `resource_group_description` | Description on the group; null leaves it unset | `null` |
| `resource_group_tag_filters` | Tag key to accepted values, rendered into `TagFilters` | `{}` |
| `resource_group_resource_type_filters` | `ResourceTypeFilters` in the group's query | `["AWS::AllSupported"]` |
| `anomaly_detection_enabled` | Create the anomaly monitor and its subscription | `true` |
| `anomaly_monitor_dimension` | `SERVICE` or `LINKED_ACCOUNT` | `"SERVICE"` |
| `anomaly_threshold` | Dollars of total absolute impact at or above which an anomaly is reported | `10` |
| `anomaly_frequency` | `DAILY`, `IMMEDIATE` or `WEEKLY` | `"DAILY"` |
| `anomaly_sns_topic_arns` | SNS topics added to the subscription alongside the emails | `[]` |
| `budgets` | Budgets keyed by the suffix appended to `name` | `{}` |
| `budget_sns_topic_arns` | SNS topics added to every budget notification | `[]` |
| `tags` | Extra tags on the resource group; an empty map is passed as null | `{}` |

Each `budgets` entry is an object:

```hcl
{
  limit_amount = string                                # required, a decimal string
  limit_unit   = optional(string, "USD")
  time_unit    = optional(string, "MONTHLY")
  budget_type  = optional(string, "COST")
  thresholds = optional(list(object({
    threshold           = number
    comparison_operator = optional(string, "GREATER_THAN")
    threshold_type      = optional(string, "PERCENTAGE")
    notification_type   = optional(string, "ACTUAL")
  })), [{ threshold = 100 }])
}
```

## Outputs

| Name | Description |
| --- | --- |
| `resource_group_arn` | ARN of the resource group, null when disabled |
| `resource_group_name` | Name of the group, which is also its id, null when disabled |
| `anomaly_monitor_arn` | ARN of the monitor; pass it to a second subscription for another audience |
| `anomaly_subscription_arn` | ARN of the anomaly subscription, null when disabled |
| `budget_names` | Budget key to the full stored budget name |
| `budget_arns` | Budget key to ARN |

## Gotchas

- Filter the resource group on the bare project tag, not on `name`. `name` is usually
  `<project>-<environment>` and no resource carries that as its `Project` tag, so the group
  matches nothing.
- `limit_amount` is a string passed to AWS verbatim, and AWS Budgets stores it as one, so `"30"`
  and `"30.0"` are different stored values. Copy the string out of state when adopting a budget.
- `anomaly_frequency = "IMMEDIATE"` requires at least one SNS subscriber; an EMAIL subscriber may
  only use `DAILY`.
- `notification_emails` order is the order the subscriber blocks and
  `subscriber_email_addresses` are written in, and duplicates are rejected by Cost Explorer.
- SNS topics must allow `costalerts.amazonaws.com` or `budgets.amazonaws.com` to publish; the
  module does not write the topic policy.
- Only the resource group takes tags, and it is regional, surfacing the provider region's
  resources. Cost Explorer and Budgets resources are global and untaggable.
- The first two budgets in an account are free; each one after that is billed per day.
