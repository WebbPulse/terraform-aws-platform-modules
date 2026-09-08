# terraform-aws-api-alarms

The alarm set for a Lambda-backed HTTP API on DynamoDB: one SNS topic with email subscribers,
Lambda `Errors` and `Throttles` alarms, either one pair per function or one pair summed across a
function per domain, HTTP API `5xx` and integration latency percentile alarms,
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
aws_cloudwatch_metric_alarm.lambda_aggregate_errors[N]      one per group of 10 lambda_function_names
aws_cloudwatch_metric_alarm.lambda_aggregate_throttles[N]   one per group of 10 lambda_function_names
aws_cloudwatch_metric_alarm.api_5xx[0]                 only with http_api_id
aws_cloudwatch_metric_alarm.api_integration_latency[0] only with http_api_id
aws_cloudwatch_metric_alarm.dynamodb_throttles["<key>"] one per dynamodb_tables entry
aws_cloudwatch_metric_alarm.dynamodb_aggregate_throttles[0]  only with dynamodb_aggregate_alarm
aws_cloudwatch_log_metric_filter.errors["<key>"]       one per error_log_groups entry
aws_cloudwatch_metric_alarm.errors[0]                  only with a non-empty error_log_groups
aws_cloudwatch_metric_alarm.standalone_lambda_errors[0]     only with lambda_errors_alarm_function_name
                                                            and no lambda_function_name
aws_cloudwatch_log_metric_filter.rate_limit_failed_open["<key>"]  one per watched log group,
                                                            only with rate_limit_fail_open_alarm
aws_cloudwatch_metric_alarm.rate_limit_failed_open[0]  only with rate_limit_fail_open_alarm
```

Alarm names:

| Resource | Alarm name |
| --- | --- |
| `lambda_errors` | `<name_prefix>-lambda-errors` |
| `lambda_throttles` | `<name_prefix>-lambda-throttles` |
| `lambda_aggregate_errors[0]` | `<name_prefix>-lambda-errors-aggregate` |
| `lambda_aggregate_errors[N]`, N > 0 | `<name_prefix>-lambda-errors-aggregate-<N+1>` |
| `lambda_aggregate_throttles[0]` | `<name_prefix>-lambda-throttles-aggregate` |
| `lambda_aggregate_throttles[N]`, N > 0 | `<name_prefix>-lambda-throttles-aggregate-<N+1>` |
| `api_5xx` | `<name_prefix>-api-5xx` |
| `api_integration_latency` | `<name_prefix>-api-integration-latency-<api_latency_statistic>` |
| `dynamodb_throttles["<key>"]` | `<table name>-throttles` |
| `dynamodb_aggregate_throttles[0]` | `<name_prefix>-dynamodb-throttles` |
| `errors[0]` | `<name_prefix>-application-errors` |
| `standalone_lambda_errors[0]` | `<name_prefix>-lambda-errors` |
| `rate_limit_failed_open[0]` | `<name_prefix>-rate-limit-failed-open` |

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
`examples/api-alarms-lambda-aggregate` is the same function-per-domain estate with the aggregate
`AWS/Lambda` alarms, which is the section below.

## Email subscriptions send a confirmation email

`notification_emails` becomes one `aws_sns_topic_subscription` per address, keyed by the address
itself. On the first apply AWS emails every address a confirmation link, and until someone clicks
it the subscription stays `PendingConfirmation` and delivers nothing. That is an out of band step
the apply cannot do for you, so plan for it: an application adopting this module from nothing
should expect one confirmation email per address per environment.

Keying the subscriptions by address means removing one address from the list destroys only that
subscription and leaves the others alone. It also means changing an address is a destroy plus a
create, and the new address gets a fresh confirmation email.

## Watching the Lambda functions

There are two forms of the function input and **exactly one of them may be set**. A plan that sets
both is rejected by a variable validation rather than silently preferring one, because the two
build different alarms and a consumer that passes both has not decided which it wants.

| Input | Shape | Alarms |
| --- | --- | --- |
| `lambda_function_name` | one function | `<prefix>-lambda-errors` and `<prefix>-lambda-throttles`, each on that function's `FunctionName` dimension |
| `lambda_function_names` plus `lambda_aggregate_alarm = true` | a function per domain | `<prefix>-lambda-errors-aggregate` and `<prefix>-lambda-throttles-aggregate`, each summing every listed function, plus a numbered pair for each further group of 10 |

`lambda_function_names` on its own creates nothing. It is the list the aggregate alarms sum over,
so it needs `lambda_aggregate_alarm = true` to do anything, and there is deliberately no per
function alarm pair behind it: a pair per function across a growing estate is exactly what the
aggregate shape exists to avoid.

### One pair of alarms for a function per domain

```hcl
lambda_function_names = [for k, m in module.lambda_api : m.function_name]

lambda_aggregate_alarm = true
```

Two alarms, whatever the function count. Each is a metric math alarm: one `metric_query` per
function carrying that function's `FunctionName` dimension with `return_data = false`, plus a SUM
expression that returns data to the alarm.

```
errors = m0 + m1 + m2 + m3     # returned to the alarm
m0     = AWS/Lambda Errors  FunctionName = <first name>   Sum over lambda_aggregate_period
m1     = AWS/Lambda Errors  FunctionName = <second name>  Sum over lambda_aggregate_period
...
```

The throttles alarm is the same expression over `Throttles`. Both share
`lambda_aggregate_threshold`, because both count the same kind of thing, and both share
`lambda_aggregate_period` and `lambda_aggregate_evaluation_periods`.

Four things follow from that construction:

- **It covers the listed functions, not the account.** The obvious alternative is one alarm on
  `AWS/Lambda` `Errors` with no `FunctionName` dimension, which is account wide and needs no list
  at all. That was rejected here: an application account also runs the staging access gate's
  authorizer function and anything else that lands in it, so a dimensionless alarm counts errors
  the application does not own and its threshold stops meaning what it says. The DynamoDB
  aggregate alarm accepts that trade because a Metrics Insights query is the only way to sum
  throttles without a table list; `AWS/Lambda` has no such constraint at these counts.
- **The names carry no function name.** They are `<name_prefix>-lambda-errors-aggregate` and
  `<name_prefix>-lambda-throttles-aggregate`. Adding a domain changes the expression on an alarm
  that already exists rather than creating another alarm to subscribe, dashboard and document.
- **The list must be maintained.** This is the price of the previous two points. A function added
  to the estate but not to `lambda_function_names` is not covered until the next apply, unlike the
  DynamoDB aggregate alarm which re-resolves its query on every evaluation. Building the list from
  the same `for_each` map that creates the functions is what keeps it in step.
- **Ten functions per alarm is the ceiling, and it is handled by chunking.** A CloudWatch alarm's
  metric math expression may reference at most 10 metrics. Up to v2.1.0 that was a hard cap on
  `lambda_function_names`. Since 2.2 the list is split into groups of at most 10 instead, and each
  group gets its own alarm pair. See below.

### Past ten functions the list chunks

`lambda_function_names` has no length limit. The module chunks it into groups of at most 10 names,
in list order, and builds one errors alarm and one throttles alarm per group:

| Names | Groups | Errors alarm names |
| --- | --- | --- |
| 1 to 10 | 1 | `<prefix>-lambda-errors-aggregate` |
| 11 to 20 | 2 | the above, plus `<prefix>-lambda-errors-aggregate-2` |
| 21 to 30 | 3 | the above, plus `<prefix>-lambda-errors-aggregate-3` |

Throttles alarms are named the same way on `-lambda-throttles-aggregate`. The first group keeps the
unsuffixed name it has always had, so nothing renames when the module is upgraded; later groups are
numbered from 2, which reads as "the second group" rather than as a zero-based index.

The metric math ids restart at `m0` inside every group, because an id is scoped to the alarm it
appears in. A full group of 10 is therefore byte-identical to what those same 10 names produced as
a whole list before chunking, and each alarm's description counts its own group rather than the
estate.

`lambda_aggregate_threshold` applies **within a group**, not across the estate: with two groups and
the default threshold of 0, one error in either group fires that group's alarm. At the default
threshold that is the same behavior as one alarm. At a raised threshold it is not, because 3 errors
in group 0 and 3 in group 1 no longer add up to 6 anywhere. An estate large enough to chunk and
wanting one number for the whole thing wants the log based alarm in `error_log_groups`, whose metric
carries no dimensions and whose single alarm sums any number of filters.

### The list order is load bearing

The order of `lambda_function_names` decides two things, so it is a list rather than a set:

- **Which `m0`, `m1` id each function gets inside its group.** Reordering within a group rewrites
  that group's expression on the next plan. The alarm watches the same total either way, so the
  diff is cosmetic, but it is a diff.
- **Which group each function lands in.** This one is not cosmetic. Inserting a name at the front
  of a list of 15 shifts the tenth name out of group 0 and into group 1, which rewrites both
  groups' expressions.

**Appending never re-chunks an earlier group.** `chunklist` fills each group before starting the
next, so the first 10 names are always group 0 whatever comes after them. Adding a domain at the end
of the list changes only the last group, or opens a new one when the last group is full. That is the
growth path to plan for: build the list from a stable source, in a stable order, and append.

`tests/lambda_aggregate.tftest.hcl` pins the single-group shape: the names, the one data-returning
query, the `FunctionName` on every contributing query, and that the per function pair is unchanged
and the aggregate pair absent when `lambda_aggregate_alarm` is false.
`tests/lambda_aggregate_chunking.tftest.hcl` pins the chunking: 12 names into two groups, 21 into
three, and that 5 and exactly 10 stay one group at `[0]` with the unsuffixed name and the same
expression v2.1.0 built. `terraform test` in this directory runs both, and neither needs
credentials.

### Attribution, and why aggregate anyway

An aggregate alarm says the estate had errors, not which function did. That is the same trade the
log based alarm and the DynamoDB aggregate alarm make, and it is made on purpose: the alarm's job
is to page someone, and CloudWatch Metrics is where they find out which function. What it buys is
worth the trade at a function per domain. Two alarms instead of two per function means two names
in the runbook however many domains there are, two billable alarm metrics instead of two per
function, and no alarm silently missing from an estate because a new domain's module call was
copied without its alarms. Each `metric_query` carries the function name as its `label`, so the
per function series are named on the alarm graph and in the notification body even though the
alarm itself is one number.

### Cost

Two alarms at $0.10 a month each per group of 10 functions, plus the metrics the math references.
An estate of four functions on the per function shape is 8 alarms; on this shape it is 2. At 25
functions it is 50 against 6. The saving is real but small, and it is not the reason to choose this
shape: the reason is one name to subscribe and one place to change a threshold.

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

## The rate limiter failing open

The shared DynamoDB backed rate limiter is a protective control, not an authorisation control. When
it cannot reach its `<prefix>-rate-limits` table it **allows** the request and logs a WARNING
carrying `rate_limit_failed_open`, because refusing every call while DynamoDB is unavailable turns a
dependency blip into a full outage, which is the worse failure.

That trade is only safe while somebody finds out it happened. Nothing else reports it: the request
succeeded, so `AWS/Lambda Errors` stays at zero, the API returns 200 and the DynamoDB alarms see a
failure the client library already swallowed. The only evidence is the WARNING, and until this alarm
exists it sits unread in a log group. `rate_limit_fail_open_alarm = true` turns those records into a
metric and puts one alarm on it:

```hcl
rate_limit_fail_open_alarm = true
```

That is one metric filter per watched log group and a single `<name_prefix>-rate-limit-failed-open`
alarm across all of them. The log groups default to `error_log_groups`, so a consumer that already
lists its functions there does not list them twice; `rate_limit_fail_open_log_groups` names a
different set, replacing that list rather than merging with it.

It is a **separate metric from the application errors alarm**, not a widened error pattern, because
the two mean different things. An application error is a request that went wrong. A fail open is a
request that went through **unprotected** while a control was down, and a responder wants to see it
on its own rather than buried in a period that is already noisy with ordinary errors. The threshold
is 0 with `GreaterThanThreshold`, so a single fail open in five minutes alarms: for a control that
is meant never to fail, the interesting fact is that it happened at all, not how often.

The filter and alarm shape is the one the errors section above explains in full. Every filter writes
the same metric name in the same namespace with **no dimensions**, which is what makes one ordinary
metric alarm the Sum across all of them, keeps the alarm count at one however many functions the
estate grows to, and keeps the alarm off metric math and its 10 metric ceiling.

### The pattern has to match the shape the service actually logs

`{ $.rate_limit_failed_open IS TRUE }`, the default, matches a JSON record with a **top level**
`rate_limit_failed_open` field whose value is the JSON boolean `true`:

```json
{"timestamp":"...","level":"WARNING","message":"Login rate limit check failed; allowing the request.",
 "rate_limit_failed_open":true,"rate_limit_operation":"record_failure","error_type":"ClientError"}
```

A JSON filter pattern selects on fields. It cannot see inside the `message` string. A service that
interpolates the flag into its message text instead, like this:

```json
{"level":"WARNING","message":"Shared rate limit check failed; allowing the request. rate_limit_failed_open=True operation=check ..."}
```

has no `rate_limit_failed_open` **field** at all, and the default pattern silently matches nothing:
the metric stays flat at 0, the alarm sits in OK forever and reports healthy while the limiter is
failing open. That is the worst possible failure for an alarm, so check which shape a service emits
before enabling this, and give the service a substring pattern if it is the second one:

```hcl
rate_limit_fail_open_filter_pattern = "\"rate_limit_failed_open=True\""
```

Two notes on that. A quoted CloudWatch Logs pattern is a plain substring match over the whole raw
event, so it works regardless of where in the record the text sits. And it is case sensitive against
what the service writes: Python's `%s` interpolation of a bool renders `True`, while `json.dumps`
of the same value renders `true`, which is exactly why the two shapes need two different patterns.

Both are worth fixing at the source eventually. A service that emits the flag as a real field gets
the default pattern, queryable `filter rate_limit_failed_open = 1` in Logs Insights, and a pattern
that keeps working when the message wording changes.

### Cost

One alarm per environment at $0.10 a month, plus the metric filters, which are free. A custom metric
is $0.30 a month, and this is one metric however many log groups publish to it, because they all
write the same dimensionless series.

## Turning parts off

`lambda_function_name = null` with `lambda_aggregate_alarm = false` drops every `AWS/Lambda`
alarm, `http_api_id = null` drops both API
alarms, `dynamodb_tables = {}` with `dynamodb_aggregate_alarm = false` drops every DynamoDB
alarm, and `error_log_groups = {}` drops every metric filter and the errors alarm with them.

`rate_limit_fail_open_alarm = false`, the default, drops the fail open filters and their alarm.

The topic is always created, so the module is also a reasonable way to own just the notification
target while alarms live elsewhere: publish `sns_topic_arn` and point them at it.

Everything added in 2.4 is off unless asked for. `rate_limit_fail_open_alarm` defaults to `false`,
and nothing else in the module reads the inputs that go with it, so a consumer that upgrades without
touching its module block gets an unchanged plan even when it already passes `error_log_groups`.
`tests/rate_limit_fail_open.tftest.hcl` pins that case directly.

2.2 lifted the 10 name cap on `lambda_function_names` by chunking it, and that is a no-op for a
consumer at 10 or fewer names. The chunk resources stayed on `count`, so a single group is still
`lambda_aggregate_errors[0]` and `lambda_aggregate_throttles[0]`, the two addresses an existing
state already holds, and a single group still gets the unsuffixed alarm names and the same
`m0 + m1 + ...` expression. No `moved` block is needed, and none would help: `moved` requires a
constant key, so a `count` index could not be moved to a computed `for_each` key anyway. That is why
the shape kept `count`. `tests/lambda_aggregate_chunking.tftest.hcl` asserts the 5 name and the
exactly-10 name cases produce the v2.1.0 alarm names at index 0, and the v2.1.0 suite
`tests/lambda_aggregate.tftest.hcl` still passes unedited.

Everything added in 2.1 is off unless asked for too. `lambda_function_names` defaults to `[]` and
`lambda_aggregate_alarm` to `false`, so a consumer on `lambda_function_name` keeps exactly the two
per function alarms it has: the aggregate resources have a `count` of 0 and nothing else in the
module reads either input. Both existing estates were checked by rendering the plan for their
current module block against the module before and after the change and diffing the result, which
came out identical.

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
| `lambda_function_name` | One function form: `FunctionName` dimension of the per function alarm pair; null skips both. Not combinable with `lambda_function_names` | `null` |
| `lambda_function_names` | Many function form: the functions the aggregate alarms sum over. Creates nothing on its own. Not combinable with `lambda_function_name`. Any length; chunked into groups of at most 10, and the order is load bearing | `[]` |
| `lambda_errors_threshold` | Sum of `Errors` per period that must be exceeded | `0` |
| `lambda_errors_period` | Period in seconds | `300` |
| `lambda_errors_evaluation_periods` | Periods evaluated | `1` |
| `lambda_throttles_threshold` | Sum of `Throttles` per period that must be exceeded | `0` |
| `lambda_throttles_period` | Period in seconds | `300` |
| `lambda_throttles_evaluation_periods` | Periods evaluated | `1` |
| `lambda_aggregate_alarm` | Create the `-lambda-errors-aggregate` and `-lambda-throttles-aggregate` pair summing `lambda_function_names`, plus a numbered pair per further group of 10 | `false` |
| `lambda_aggregate_threshold` | Errors, or throttles, summed across the functions one alarm covers per period to exceed. One value for every aggregate alarm, applied within each group | `0` |
| `lambda_aggregate_period` | Period in seconds of every metric feeding the aggregate alarms | `300` |
| `lambda_aggregate_evaluation_periods` | Periods evaluated by each aggregate alarm | `1` |
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
| `rate_limit_fail_open_alarm` | Create one `<name_prefix>-rate-limit-failed-open` alarm over the limiter's fail open records | `false` |
| `rate_limit_fail_open_log_groups` | Log groups to watch for fail open records; null reuses `error_log_groups` | `null` |
| `rate_limit_fail_open_filter_pattern` | Filter pattern the fail open metric filters match | `{ $.rate_limit_failed_open IS TRUE }` |
| `rate_limit_fail_open_metric_name` | Metric every fail open filter publishes to, null for `<name_prefix>-rate-limit-failed-open` | `null` |
| `rate_limit_fail_open_alarm_threshold` | Fail open records across every log group per period to exceed | `0` |
| `rate_limit_fail_open_alarm_period` | Period in seconds | `300` |
| `rate_limit_fail_open_alarm_evaluation_periods` | Periods evaluated | `1` |
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
| `lambda_alarm_names` | Every `AWS/Lambda` alarm name the module created, empty when no function input is set |
| `lambda_aggregate_alarm_names` | Every aggregate alarm name, all the errors ones first, each in chunk order; empty when `lambda_aggregate_alarm` is false |
| `lambda_aggregate_alarm_arns` | Every aggregate alarm ARN, all the errors ones first, each in chunk order; empty when `lambda_aggregate_alarm` is false |
| `lambda_aggregate_errors_alarm_names` | Names of every aggregate errors alarm, one per group, in chunk order |
| `lambda_aggregate_throttles_alarm_names` | Names of every aggregate throttles alarm, one per group, in chunk order |
| `lambda_aggregate_errors_alarm_arns` | ARNs of every aggregate errors alarm, one per group; the output to build a composite alarm or a dashboard on |
| `lambda_aggregate_throttles_alarm_arns` | ARNs of every aggregate throttles alarm, one per group |
| `lambda_aggregate_errors_alarm_arn` | ARN of the **first** aggregate errors alarm, `null` when it is off. Predates chunking; use the plural output past 10 functions |
| `lambda_aggregate_throttles_alarm_arn` | ARN of the **first** aggregate throttles alarm, `null` when it is off. Predates chunking; use the plural output past 10 functions |
| `lambda_aggregate_function_name_chunks` | The function names as the module grouped them, one list per alarm pair, for a runbook that has to say which alarm covers which function |
| `api_alarm_names` | The two API alarm names, empty when there is no API |
| `dynamodb_alarm_names` | Table alarm names keyed by their `dynamodb_tables` key |
| `dynamodb_aggregate_alarm_name` | Name of the aggregate alarm, `null` when it is off |
| `error_alarm_name` | Name of the application errors alarm, `null` when `error_log_groups` is empty |
| `error_metric_filter_names` | Metric filter names keyed by their `error_log_groups` key |
| `error_metric` | `{ namespace, name }` of the metric the filters publish to, for a dashboard |
| `rate_limit_fail_open_alarm_name` | Name of the rate limit fail open alarm, `null` when it is off |
| `rate_limit_fail_open_metric_filter_names` | Fail open metric filter names keyed by their log group key |
| `rate_limit_fail_open_metric` | `{ namespace, name }` of the metric the fail open filters publish to, for a dashboard |

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

#### Moving Portfolio to the aggregate Lambda alarms

Portfolio is splitting its one API function into a function per domain, which is what the
aggregate alarms are for. The change is to swap the one function input for the list plus the flag:

```hcl
  lambda_function_names = [for k, m in module.lambda_api : m.function_name]

  lambda_aggregate_alarm = true
```

That plans two destroys and two adds. The destroys are `<prefix>-lambda-errors` and
`<prefix>-lambda-throttles`, the adds are the two `-aggregate` names, and no alarm is replaced in
place because the names differ. Nothing outside the alarms is touched, but the estate is uncovered
between the destroy and the new alarms reaching `OK`, and the two old names disappear from
anything referencing them. Adding the aggregate pair first, while `lambda_function_name` still
points at the monolith, is not possible in one module call because the two inputs are mutually
exclusive; a second module call with its own `name_prefix` would do it at the cost of a second
topic, which is not worth it for a gap of one evaluation period.

#### Growing past ten domain functions

CarModPicker lands on exactly 10 names, nine domain functions plus the monolith, which is one group
and one alarm pair. The eleventh function is the one that opens group 1 and adds
`<prefix>-lambda-errors-aggregate-2` and `<prefix>-lambda-throttles-aggregate-2`. That plan is 2 to
add and 1 to change: the two new alarms, plus the expression on group 0 only if the new name was
inserted rather than appended. Append, and group 0 does not move at all.

Two operational consequences to write into the runbook before that happens:

- There are now four alarm names, not two, and anything that lists them by hand needs the new pair.
  `lambda_aggregate_errors_alarm_names` and `lambda_aggregate_alarm_names` already carry them.
- `lambda_aggregate_threshold` is per group. At the default of 0 nothing changes. At a raised
  threshold, errors split across two groups no longer add up.

A consumer that wired `lambda_aggregate_errors_alarm_arn`, the singular output, into a composite
alarm or a dashboard should move to `lambda_aggregate_errors_alarm_arns` at the same time. The
singular output still resolves and reports group 0, which is deliberate so nothing breaks on
upgrade, but a composite alarm built on it would silently cover only the first ten functions.

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
