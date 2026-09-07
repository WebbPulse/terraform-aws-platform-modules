# terraform-aws-api-alarms

The alarm set for a Lambda-backed HTTP API on DynamoDB: one SNS topic with email subscribers,
Lambda `Errors` and `Throttles` alarms, HTTP API `5xx` and integration latency percentile alarms,
and one read plus write throttle alarm per DynamoDB table. It is the shape CarModPicker already
runs by hand, lifted into one place so the next application gets the same coverage without
retyping it, and so a change to a threshold reaches every application on its next plan.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms`. The function,
the API and the tables stay with the consumer; the module needs only a function name, an API id
and a map of table names.

## What it creates

```
aws_sns_topic.alarms                                   <name_prefix>-alarms
aws_sns_topic_subscription.email["<address>"]          one per notification_emails entry
aws_cloudwatch_metric_alarm.lambda_errors[0]           only with lambda_function_name
aws_cloudwatch_metric_alarm.lambda_throttles[0]        only with lambda_function_name
aws_cloudwatch_metric_alarm.api_5xx[0]                 only with http_api_id
aws_cloudwatch_metric_alarm.api_integration_latency[0] only with http_api_id
aws_cloudwatch_metric_alarm.dynamodb_throttles["<key>"] one per dynamodb_tables entry
```

Alarm names:

| Resource | Alarm name |
| --- | --- |
| `lambda_errors` | `<name_prefix>-lambda-errors` |
| `lambda_throttles` | `<name_prefix>-lambda-throttles` |
| `api_5xx` | `<name_prefix>-api-5xx` |
| `api_integration_latency` | `<name_prefix>-api-integration-latency-<api_latency_statistic>` |
| `dynamodb_throttles["<key>"]` | `<table name>-throttles` |

## Usage

```hcl
module "alarms" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
  version = "~> 1.6"

  name_prefix         = local.prefix
  notification_emails = ["alerts@example.com"]

  # With lambda-function and dynamodb-tables adopted, wire the module outputs. An app that still
  # owns those resources passes aws_lambda_function.api.function_name and
  # { for k, t in aws_dynamodb_table.tables : k => t.name } instead.
  lambda_function_name = module.lambda_api.function_name
  http_api_id          = module.api.api_id
  dynamodb_tables      = module.dynamodb.table_names
}
```

`examples/api-alarms-basic` at the repository root is the complete version of that, with the
function, the API and the tables around it.

## Email subscriptions send a confirmation email

`notification_emails` becomes one `aws_sns_topic_subscription` per address, keyed by the address
itself. On the first apply AWS emails every address a confirmation link, and until someone clicks
it the subscription stays `PendingConfirmation` and delivers nothing. That is an out of band step
the apply cannot do for you, so plan for it: an application adopting this module from nothing
should expect one confirmation email per address per environment.

Keying the subscriptions by address means removing one address from the list destroys only that
subscription and leaves the others alone. It also means changing an address is a destroy plus a
create, and the new address gets a fresh confirmation email.

## Watching the DynamoDB tables

`dynamodb_tables` is a map of `for_each` key to table name, not a list, and the two halves do
different jobs. The key is the alarm's Terraform address, so an application adopting alarms it
already has keys the map exactly the way its `aws_dynamodb_table` resource is keyed. The value is
the real table name: it is both the `TableName` dimension and the alarm name, `<table
name>-throttles`. When a table's Terraform key already is its name, or an application is starting
from a plain list, `{ for n in names : n => n }` is the whole conversion.

Each alarm is a single metric math alarm rather than two alarms, so a table that throttles reads
and a table that throttles writes both raise one alarm:

```
throttles = reads + writes    # returned to the alarm
reads     = AWS/DynamoDB ReadThrottleEvents  Sum over dynamodb_throttles_period
writes    = AWS/DynamoDB WriteThrottleEvents Sum over dynamodb_throttles_period
```

## Turning parts off

`lambda_function_name = null` drops both Lambda alarms, `http_api_id = null` drops both API
alarms, and `dynamodb_tables = {}` drops the table alarms. The topic is always created, so the
module is also a reasonable way to own just the notification target while alarms live elsewhere:
publish `sns_topic_arn` and point them at it.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name_prefix` | Prefix for the topic and the Lambda and API alarm names, normally `local.prefix` | required |
| `notification_emails` | Addresses subscribed to the topic; each gets a confirmation email | `[]` |
| `sns_topic_name` | Topic name, null for `<name_prefix>-alarms` | `null` |
| `sns_topic_tags` | Extra tags on the topic only | `{}` |
| `tags` | Tags on the topic and every alarm | `{}` |
| `lambda_function_name` | `FunctionName` dimension; null skips both Lambda alarms | `null` |
| `lambda_errors_threshold` | Sum of `Errors` per period that must be exceeded | `0` |
| `lambda_errors_period` | Period in seconds | `300` |
| `lambda_errors_evaluation_periods` | Periods evaluated | `1` |
| `lambda_throttles_threshold` | Sum of `Throttles` per period that must be exceeded | `0` |
| `lambda_throttles_period` | Period in seconds | `300` |
| `lambda_throttles_evaluation_periods` | Periods evaluated | `1` |
| `http_api_id` | `ApiId` dimension; null skips both API alarms | `null` |
| `api_5xx_threshold` | Sum of `5xx` per period that must be exceeded | `0` |
| `api_5xx_period` | Period in seconds | `300` |
| `api_5xx_evaluation_periods` | Periods evaluated | `1` |
| `api_latency_threshold_ms` | `IntegrationLatency` in milliseconds to exceed | `10000` |
| `api_latency_statistic` | Percentile; also the alarm name suffix | `"p99"` |
| `api_latency_period` | Period in seconds | `300` |
| `api_latency_evaluation_periods` | Periods evaluated | `1` |
| `dynamodb_tables` | Map of `for_each` key to table name | `{}` |
| `dynamodb_throttles_threshold` | Read plus write throttle events per period to exceed | `0` |
| `dynamodb_throttles_period` | Period in seconds of both metrics | `300` |
| `dynamodb_throttles_evaluation_periods` | Periods evaluated | `1` |
| `comparison_operator` | Comparison on every alarm | `"GreaterThanThreshold"` |
| `treat_missing_data` | Missing data handling on every alarm | `"notBreaching"` |
| `notify_on_ok` | Put the topic in `ok_actions` as well as `alarm_actions` | `true` |
| `extra_alarm_actions` | Extra action ARNs on every alarm, alongside the topic | `[]` |

Every threshold, period and evaluation count defaults to the value CarModPicker runs today, which
is why its adoption passes none of them.

## Outputs

| Name | Description |
| --- | --- |
| `sns_topic_arn` | ARN of the alarm topic |
| `sns_topic_name` | Name of the alarm topic |
| `subscription_arns` | Email subscription ARNs keyed by address |
| `alarm_names` | Every alarm name, sorted |
| `alarm_arns` | Every alarm ARN, sorted |
| `lambda_alarm_names` | The two Lambda alarm names, empty when there is no function |
| `api_alarm_names` | The two API alarm names, empty when there is no API |
| `dynamodb_alarm_names` | Table alarm names keyed by their `dynamodb_tables` key |

## Adoption

### CarModPicker

CarModPicker has every one of these resources in state today, so its adoption is a pure `moved`
exercise. `terraform/monitoring.tf` becomes the module block and the `moved` blocks below, and
nothing else in the repository changes. The speculative plan on `CarModPicker-staging` reads
**32 to move, 0 to add, 0 to change, 0 to destroy**.

```hcl
module "alarms" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
  version = "~> 1.6"

  name_prefix         = local.prefix
  notification_emails = ["tyler@webbpulse.com", "tylert2610@gmail.com"]

  lambda_function_name = module.lambda_api.function_name
  http_api_id          = module.api.api_id

  # module.dynamodb.table_names is keyed by the dynamodb_tables.json key so each alarm keeps the
  # address it has in state; the value is the real table name, which is what
  # "<table name>-throttles" is built from. Before adopting dynamodb-tables this was
  # { for k, t in aws_dynamodb_table.tables : k => t.name }.
  dynamodb_tables = module.dynamodb.table_names

  # Every threshold, period and evaluation count is the module default and matches state, so
  # none of them is passed here.
}

moved {
  from = aws_sns_topic.alarms
  to   = module.alarms.aws_sns_topic.alarms
}

moved {
  from = aws_sns_topic_subscription.alarms_tyler_webb
  to   = module.alarms.aws_sns_topic_subscription.email["tyler@webbpulse.com"]
}

moved {
  from = aws_sns_topic_subscription.alarms_tyler_gmail
  to   = module.alarms.aws_sns_topic_subscription.email["tylert2610@gmail.com"]
}

moved {
  from = aws_cloudwatch_metric_alarm.lambda_errors
  to   = module.alarms.aws_cloudwatch_metric_alarm.lambda_errors[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.lambda_throttles
  to   = module.alarms.aws_cloudwatch_metric_alarm.lambda_throttles[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.api_5xx
  to   = module.alarms.aws_cloudwatch_metric_alarm.api_5xx[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.api_integration_latency_p99
  to   = module.alarms.aws_cloudwatch_metric_alarm.api_integration_latency[0]
}

moved {
  from = aws_cloudwatch_metric_alarm.dynamodb_throttles
  to   = module.alarms.aws_cloudwatch_metric_alarm.dynamodb_throttles
}
```

Three details are what make that plan clean:

- The Lambda and API alarms are `count`-gated in the module, so their `moved` targets carry `[0]`.
  The DynamoDB alarms are `for_each`-gated on `dynamodb_tables`, whose keys are the same keys
  `aws_dynamodb_table.tables` uses, so the whole resource moves in one block and every key follows.
- The subscription keys are the addresses themselves, which is why the two named subscription
  resources move to `email["tyler@webbpulse.com"]` and `email["tylert2610@gmail.com"]`.
- `tags = {}` on the alarms and the topic is what an unset `tags` already stores on provider 5.x,
  and both applications tag through provider `default_tags` anyway.

The `moved` blocks can be deleted after one apply in each environment.

### WebbPulse-Portfolio

WebbPulse-Portfolio has no alarms today, so there is nothing to move. Its plan is **all adds**,
17 of them with the block below: one topic, two email subscriptions, the two Lambda alarms, the
two API alarms, and one alarm per DynamoDB table, which with the current `local.dynamodb_tables`
is ten tables (nine entity tables plus `meta`). Applying it also sends a confirmation email to
each address in `notification_emails`, and the alarms deliver nothing to an address until that
address clicks the link.

Add this as `terraform/monitoring.tf`:

```hcl
module "alarms" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
  version = "~> 1.6"

  name_prefix         = local.prefix
  notification_emails = ["tyler@webbpulse.com", "tylert2610@gmail.com"]

  lambda_function_name = module.lambda_api.function_name
  http_api_id          = module.api.api_id

  # module.dynamodb.table_names is keyed by entity and each table is named
  # "${local.prefix}-${key}", so this is the same shape CarModPicker passes. Before adopting
  # dynamodb-tables this was { for k, t in aws_dynamodb_table.this : k => t.name }.
  dynamodb_tables = module.dynamodb.table_names
}
```

Every threshold keeps its default, so Portfolio starts on the same numbers CarModPicker runs. If
its API is noisier, `api_latency_threshold_ms` and the `*_evaluation_periods` inputs are the two
places to loosen first, and `notify_on_ok = false` is the way to stop the OK emails without
losing the alarms.

## Not covered

Composite alarms, anomaly detection bands, dashboards, alarms on the DynamoDB
`SystemErrors`, `UserErrors` or consumed-capacity metrics, CloudFront and WAF alarms, Chatbot or
PagerDuty subscriptions beyond `extra_alarm_actions`, and a topic policy or KMS key on the topic.
Each is an additive input or a sibling module if an application needs it.
