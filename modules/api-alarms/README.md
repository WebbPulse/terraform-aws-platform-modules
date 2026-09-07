# terraform-aws-api-alarms

The alarm set for a Lambda-backed HTTP API on DynamoDB: one SNS topic with email subscribers,
Lambda `Errors` and `Throttles` alarms, HTTP API `5xx` and integration latency percentile alarms,
DynamoDB throttle alarms, either one for the whole environment or one per table, and an optional
CloudWatch Logs metric filter alarm on the errors the application itself logs. It is the
shape CarModPicker already runs by hand, lifted into one place so the next application gets the
same coverage without retyping it, and so a change to a threshold reaches every application on
its next plan.

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
aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles[0]  only with dynamodb_aggregate_alarm
aws_cloudwatch_log_metric_filter.errors["<key>"]       one per error_log_groups entry
aws_cloudwatch_metric_alarm.errors[0]                  only with a non-empty error_log_groups
aws_cloudwatch_metric_alarm.standalone_lambda_errors[0]     only with lambda_errors_alarm_function_name
                                                            and no lambda_function_name
```

Alarm names:

| Resource | Alarm name |
| --- | --- |
| `lambda_errors` | `<name_prefix>-lambda-errors` |
| `lambda_throttles` | `<name_prefix>-lambda-throttles` |
| `api_5xx` | `<name_prefix>-api-5xx` |
| `api_integration_latency` | `<name_prefix>-api-integration-latency-<api_latency_statistic>` |
| `dynamodb_throttles["<key>"]` | `<table name>-throttles` |
| `dynamodb_aggregate_throttles[0]` | `<name_prefix>-dynamodb-throttles` |
| `errors[0]` | `<name_prefix>-application-errors` |
| `standalone_lambda_errors[0]` | `<name_prefix>-lambda-errors` |

## Usage

```hcl
module "alarms" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
  version = "~> 1.7"

  name_prefix         = local.prefix
  notification_emails = ["alerts@example.com"]

  # With lambda-function and dynamodb-tables adopted, wire the module outputs. An app that still
  # owns those resources passes aws_lambda_function.api.function_name and
  # { for k, t in aws_dynamodb_table.tables : k => t.name } instead.
  lambda_function_name = module.lambda_api.function_name
  http_api_id          = module.api.api_id

  # One alarm for every table in the environment. It needs no table list; pass
  # dynamodb_tables = module.dynamodb.table_names instead for the per table shape.
  dynamodb_aggregate_alarm = true
}
```

`examples/api-alarms-basic` at the repository root is the complete version of that, with the
function, the API and the tables around it. `examples/api-alarms-log-errors` is the other shape: a
function per domain, one metric filter each, and one alarm on the errors they log.

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

There are two shapes, and an application picks one. `dynamodb_aggregate_alarm = true` is the
default recommendation: a single alarm for the whole environment, with no table list to maintain
and automatic coverage of tables added later. `dynamodb_tables` is the original per table shape,
which names each alarm after its table and is the more sensitive of the two on batch writes; the
section below on what the aggregate alarm misses is the thing to read before choosing. Setting
both is allowed and gives you both sets, which is normally a mistake but is the honest answer for
an application that wants the aggregate alarm's coverage and the per table alarms' sensitivity.

### One alarm for the environment

```hcl
dynamodb_aggregate_alarm = true
dynamodb_tables          = {}
```

That creates `<name_prefix>-dynamodb-throttles` and nothing else. It is one CloudWatch Metrics
Insights query:

```
throttles = SELECT SUM(ThrottledRequests) FROM SCHEMA("AWS/DynamoDB", TableName, Operation)
```

Three things follow from that:

- **No table list.** The query is resolved on every evaluation, so a table added after the apply
  is covered without a Terraform change and a dropped table falls out on its own. This is the
  main reason to prefer it: the per table shape silently stops covering a new table until someone
  re-applies.
- **Account wide, not prefix filtered.** `SCHEMA("AWS/DynamoDB", ...)` matches every table in the
  account and Region, not only the ones named after `name_prefix`. That is right for these
  applications, where an environment is its own account. An account holding two environments would
  see one environment's throttling raise the other's alarm, and wants the per table shape or a
  `WHERE` clause the module does not expose yet.
- **One query is the ceiling.** An alarm may carry only one Metrics Insights query. Two queries
  plus a math expression summing them is rejected by `PutMetricAlarm` with
  `ValidationError: Invalid metrics list`, which is why this alarm cannot be
  `ReadThrottleEvents + WriteThrottleEvents` the way the per table alarms are. One query plus
  metric math *over that one query* is accepted, so a future threshold on a rate rather than a
  count is still open.

### What this alarm misses

`ThrottledRequests` is the only DynamoDB metric that covers reads and writes on its own, so a
single query alarm has to use it. It is not the same signal as the per table alarms, and the
difference is worth knowing before relying on it.

`ThrottledRequests` counts a request in which *any* event was throttled, with one exception: for
a batch operation such as `BatchGetItem` or `BatchWriteItem` it increments only when *every* item
in the batch was throttled. A `BatchWriteItem` of 25 items where 24 are throttled and one succeeds
increments nothing. `WriteThrottleEvents`, which the per table alarms use, would count all 24.

So this alarm is the right shape for the failure it exists to catch, a table or an index actually
running out of capacity, where throttling is broad and sustained rather than one item in one
batch. It is weaker than the per table alarms at catching light, partial throttling inside batch
writes. An application whose write path is mostly batched and which wants that sensitivity should
stay on `dynamodb_tables`, or run both.

`dynamodb_aggregate_period` defaults to 60, not the 300 the rest of the module uses. A Metrics
Insights alarm is standard resolution and evaluates every 60 seconds, so 60 is the only period
AWS documents for it. The validation accepts multiples of 60 and rejects the 10 and 30 the other
periods allow.

### Cost

CloudWatch bills a Metrics Insights alarm per *metric the query matches*, at the same $0.10 per
month as an ordinary alarm metric. `ThrottledRequests` carries an `Operation` dimension, so the
query matches one series per table *per operation actually exercised*, and the bill depends on
how varied the access pattern is rather than on the table count alone. An environment with 25
tables and a handful of operations each lands in the same range as the 25 per table alarms it
replaces, which cost 25 x 2 x $0.10 = $5.00 a month; a wider spread of operations costs more, a
narrow one less.

Cost is not the reason to prefer this shape, and it is worth watching on the first bill. What the
aggregate shape buys is one alarm resource instead of 25, no table list to keep in step, and
coverage of tables that do not exist yet. What it costs is per table attribution in the alarm
itself: the notification says the environment throttled, not which table did, and CloudWatch
Metrics is where you find out which.

### One alarm per table

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

### Migrating from the per table shape

Setting `dynamodb_aggregate_alarm = true` and emptying `dynamodb_tables` in the same change plans
one add and one destroy per table. The destroys are alarms, so nothing but the alarms is at risk,
but the environment is uncovered between the destroy and the new alarm reaching `OK`, and the
`<table name>-throttles` names disappear from anything that referenced them, such as a dashboard
or a runbook. Applying the aggregate alarm first and emptying `dynamodb_tables` in a second apply
avoids the gap at the price of a short overlap where both fire.

## Errors from the logs

`AWS/Lambda Errors` counts an invocation that raised. It is silent about a request the function
handled without crashing and logged an error for: a caught failure from a downstream call, a
rejected payload, a retry that gave up, a background task that failed after the response went out.
Those are most of what actually goes wrong in a running application, and the only place they exist
is the logs.

`error_log_groups` closes that gap. It is a map of short name to log group name, and it creates one
`aws_cloudwatch_log_metric_filter` per entry plus **one** alarm across all of them:

```hcl
error_log_groups = {
  posts = "/aws/lambda/webbpulse-staging-posts"
  users = "/aws/lambda/webbpulse-staging-users"
  auth  = "/aws/lambda/webbpulse-staging-auth"
}
```

That is three filters named `webbpulse-staging-posts-errors`, `-users-errors` and `-auth-errors`,
and a single `webbpulse-staging-application-errors` alarm. The key is the domain the function
serves, because it is what a responder reads in the filter name; the value is the real log group,
normally `/aws/lambda/<function name>`.

### How several filters become one alarm

Every filter writes the **same metric name in the same namespace with no dimensions**. That is
what makes a single ordinary metric alarm the sum across all of them, and it is worth being
precise about why, because the obvious alternative does not work.

A CloudWatch metric is identified by its namespace, its name **and its dimensions**. AWS puts it
this way: dimensions are "part of the unique identifier for a metric, whenever a unique name/value
pair is extracted from your logs, you are creating a new variation of that metric". So a filter
that tagged each function with a `service` dimension would not produce one metric with a
breakdown; it would produce one **separate metric per function**. A plain alarm on that metric name
would then watch a single arbitrary series, not the total, and summing them back would take metric
math, which tops out at 10 metrics in one alarm. That caps the design at 10 functions, and the
estate is heading for roughly 28.

With no dimensions there is exactly one series. Three filters, or thirty, all publish into it, and
`Sum` over a period is the number of error records across every watched log group. The alarm is an
ordinary metric alarm, so unlike the aggregate DynamoDB alarm it carries neither the one Metrics
Insights query per alarm limit nor the 10 metric metric math limit. Adding the eleventh, or the
fiftieth, log group changes nothing about the alarm.

The second reason for no dimensions is a hard AWS constraint rather than a preference: **"If you
assign dimensions to a metric created by a metric filter, you can't assign a default value for that
metric."** The filters set `default_value = 0`, which is what makes the metric report a real zero
in periods that had logs but no errors, instead of a gap. Gaps and `treat_missing_data` interact in
ways that make an alarm harder to reason about, so the default value is worth keeping and
dimensions are what would have to go.

The trade is attribution. The alarm says the environment logged errors; it does not say which
function. The filter names and the log groups are where a responder looks next. That is the same
trade the aggregate DynamoDB alarm makes, and it is the shape that scales to a function per domain.

### The JSON log format the pattern expects

The default `error_filter_pattern` is:

```
{ $.level = "ERROR" }
```

It matches a log event that parses as JSON and whose top level `level` field is exactly the string
`ERROR`. The shared observability package emits records of this shape, and it is also what Lambda's
own `log_format = "JSON"` and AWS Lambda Powertools write:

```json
{
  "timestamp": "2026-09-07T18:31:02.114Z",
  "level": "ERROR",
  "message": "failed to fetch build for part 41",
  "service": "webbpulse-staging-posts",
  "trace_id": "1-68bd0c96-1f0a2b3c4d5e6f7a8b9c0d1e",
  "request_id": "c4f9a1e2-7b3d-4a5e-9f10-2b3c4d5e6f7a"
}
```

Only `level` is load-bearing for the filter. The other fields are what make the log event useful
once the alarm has sent someone to look, and `trace_id` is what joins the record to its X-Ray
trace.

The pattern is an input rather than a constant because the field name is a convention, not a law.
An application whose logger writes `severity`, or one that wants `CRITICAL` to alarm as well,
overrides it:

```hcl
error_filter_pattern = "{ $.level = \"ERROR\" || $.level = \"CRITICAL\" }"
```

Case matters. Filter patterns are case sensitive, so `"Error"` does not match `"ERROR"`.

### A Text format log group never matches

This is the failure mode to know about, because it is invisible.

A JSON filter pattern is only applied to log events that parse as JSON. A Lambda function with
`logging_config { log_format = "Text" }` writes plain lines, so `{ $.level = "ERROR" }` matches
nothing in its log group, the metric stays at its default value of 0, and the alarm sits in `OK`
forever. **Nothing errors.** No apply fails, no filter is rejected, and the module cannot detect
it: whether a log group's events are JSON is a property of the events, not of the log group, so
there is nothing in Terraform to validate against.

An empty alarm and a healthy application look identical from the console. Before relying on this
alarm, check the log group has JSON events in it and that a real error record matches, either in
the CloudWatch console's **Test pattern** box on the filter or by watching the metric after
deliberately logging an error.

WebbPulse-Portfolio sets `log_format = "Text"` on its Lambda today. That has to flip to `"JSON"`
before its metric filter can parse anything. It is an in-place function update, safe, but it shows
in a plan.

Two smaller cases fail the same quiet way: metric filters are supported only on log groups in the
**Standard** log class, not Infrequent Access, and filters never apply retroactively, so the metric
begins at the moment of the apply and a dashboard over the preceding hour is empty rather than
zero.

### Cost

Each distinct metric a filter publishes is a custom metric, and with no dimensions every log group
in the map shares one. So the whole feature is **one custom metric plus one alarm** for the
environment, regardless of how many functions it watches. That is the other reason not to reach for
dimensions: a `service` dimension across 28 functions would be 28 custom metrics rather than one.

### Only the Lambda errors alarm

`lambda_function_name` creates the `-lambda-errors` and `-lambda-throttles` pair together.
`lambda_errors_alarm_function_name` is for an application that wants only the errors half, which is
the common case once the log based alarm is carrying the real signal and the function behind the
API is just one of many.

The two inputs produce an alarm of the same name, `<name_prefix>-lambda-errors`, and two CloudWatch
alarms cannot share a name in a Region. Rather than let that become an apply time collision, the
module resolves it: **`lambda_function_name` wins, and `lambda_errors_alarm_function_name` creates
nothing when it is set.** Setting both is therefore safe, which is what lets an application move
from one to the other across two applies without a destroy and create in between. It reuses
`lambda_errors_threshold`, `lambda_errors_period` and `lambda_errors_evaluation_periods`, so an
application that has tuned those keeps them.

## Turning parts off

`lambda_function_name = null` drops both Lambda alarms, `http_api_id = null` drops both API
alarms, `dynamodb_tables = {}` with `dynamodb_aggregate_alarm = false` drops every DynamoDB
alarm, and `error_log_groups = {}` drops every metric filter and the errors alarm with them.

The topic is always created, so the module is also a reasonable way to own just the notification
target while alarms live elsewhere: publish `sns_topic_arn` and point them at it.

Everything added in 1.8 is off unless asked for. `error_log_groups` defaults to `{}` and
`lambda_errors_alarm_function_name` to `null`, so an application that upgrades without changing its
module block gets a byte-identical plan: no new resources, no changed attributes, nothing to
review. Both existing consumers were checked that way before the change was released.

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
| `dynamodb_aggregate_alarm` | Create one `<name_prefix>-dynamodb-throttles` alarm over every table | `false` |
| `dynamodb_aggregate_threshold` | Throttled requests across all tables per period to exceed | `0` |
| `dynamodb_aggregate_period` | Period in seconds of the query; 60 or a multiple of it | `60` |
| `dynamodb_aggregate_evaluation_periods` | Periods evaluated | `1` |
| `error_log_groups` | Log groups to watch for JSON error records, map of short name to log group name; empty creates nothing | `{}` |
| `error_filter_pattern` | Filter pattern the metric filters match | `{ $.level = "ERROR" }` |
| `error_metric_namespace` | Custom namespace for the error metric; must not start with `AWS/` | `"WebbPulse/Application"` |
| `error_metric_name` | Metric every filter publishes to, null for `<name_prefix>-application-errors` | `null` |
| `error_alarm_threshold` | Error records across every log group per period to exceed | `0` |
| `error_alarm_period` | Period in seconds | `300` |
| `error_alarm_evaluation_periods` | Periods evaluated | `1` |
| `lambda_errors_alarm_function_name` | Create only the `-lambda-errors` alarm on this function; ignored when `lambda_function_name` is set | `null` |
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
| `lambda_alarm_names` | The `AWS/Lambda` alarm names, empty when no function input is set |
| `api_alarm_names` | The two API alarm names, empty when there is no API |
| `dynamodb_alarm_names` | Table alarm names keyed by their `dynamodb_tables` key |
| `dynamodb_aggregate_alarm_name` | Name of the aggregate alarm, `null` when it is off |
| `error_alarm_name` | Name of the application errors alarm, `null` when `error_log_groups` is empty |
| `error_metric_filter_names` | Metric filter names keyed by their `error_log_groups` key |
| `error_metric` | `{ namespace, name }` of the metric the filters publish to, for a dashboard |

## Adoption

### CarModPicker

CarModPicker has every one of these resources in state today, so its adoption is a pure `moved`
exercise. `terraform/monitoring.tf` becomes the module block and the `moved` blocks below, and
nothing else in the repository changes. The speculative plan on `CarModPicker-staging` reads
**32 to move, 0 to add, 0 to change, 0 to destroy**.

```hcl
module "alarms" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
  version = "~> 1.7"

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

Since v1.7.0 CarModPicker runs the aggregate alarm instead, so its block is now

```hcl
  dynamodb_aggregate_alarm = true
  dynamodb_tables          = {}
```

which replaced its 25 per table alarms with one. The `moved` blocks above are still the right
first step for an application adopting the module with per table alarms already in state; switch
to the aggregate shape afterwards, as its own change, so the moves and the replacements are two
readable plans rather than one.

### WebbPulse-Portfolio

WebbPulse-Portfolio had no alarms before it adopted this module, so there was nothing to move.
Starting from nothing the block below is **all adds**, eight of them: one topic, two email
subscriptions, the two Lambda alarms, the two API alarms, and the one aggregate DynamoDB alarm.
Applying it also sends a confirmation email to each address in `notification_emails`, and the
alarms deliver nothing to an address until that address clicks the link.

Add this as `terraform/monitoring.tf`:

```hcl
module "alarms" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
  version = "~> 1.7"

  name_prefix         = local.prefix
  notification_emails = ["tyler@webbpulse.com", "tylert2610@gmail.com"]

  lambda_function_name = module.lambda_api.function_name
  http_api_id          = module.api.api_id

  # One alarm across every table in the environment, so there is no table list to keep in step.
  dynamodb_aggregate_alarm = true
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

On the log side specifically: subscription filters to a SaaS log destination, per function error
alarms or a `service` dimension on the error metric (see the section above for why the metric is
dimensionless), metric filters on anything but errors such as a latency field or a warning count,
and creating or setting retention on the log groups themselves. Log groups belong to whoever
creates the function; this module only reads their names.
