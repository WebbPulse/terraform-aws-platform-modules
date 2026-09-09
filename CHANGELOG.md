# Changelog

One tag covers every submodule in this repository, so this file is per release, not per module.
Each entry names the modules a release touched. Releases before 2.2.0 were documented in their tag
messages and on the GitHub release; they are summarised here from those, and the tag message stays
the authoritative record for them.

Consumers pin `~> MAJOR.MINOR` and pick up later minors on their next plan, so an entry marked
**no plan change** is one an existing consumer can take without reviewing a diff.

## 2.5.1

### `http-api`: no authorizer id on a route that takes no authorizer

A route whose effective `authorization_type` was `NONE` or `AWS_IAM` was still handed
`var.authorizer_id`. Neither type takes an authorizer: API Gateway accepts the create with one
attached, ignores it and stores nothing, so the route reads back `authorizer_id = ""` while the
configuration still names an authorizer, and every later plan shows a perpetual in-place
`authorizer_id: "" -> "..."` update on it. Portfolio staging hit this on the two public
`.well-known` routes it opts out of the access gate, which have to answer anonymously because the
API Gateway JWT authorizer fetches them itself.

- `authorizer_id` now resolves to `null` unless the route's effective `authorization_type` is
  `CUSTOM` or `JWT`. The per-route `authorizer_id` override is unchanged for those two types, and
  the module-wide `authorizer_id` still reaches every route that does not opt out, `$default`
  included.
- **No plan change** for an API whose routes are all `CUSTOM`, which is every consumer that has not
  set `authorization_type = "NONE"` or `"AWS_IAM"` on a route. A consumer that has one of those
  routes gets a single in-place update on it that then stops recurring.

## 2.4.0

### `api-alarms`: one alarm for the rate limiter failing open

The shared DynamoDB backed rate limiter allows a request when it cannot reach its
`<prefix>-rate-limits` table, and logs a WARNING carrying `rate_limit_failed_open` instead of
refusing traffic. Nothing reported that: the request succeeded, so `AWS/Lambda Errors` stays at zero
and the API returns 200 while the limit is not being enforced. `rate_limit_fail_open_alarm = true`
turns those records into a metric and puts one alarm on it.

- One `aws_cloudwatch_log_metric_filter` per watched log group, named
  `<name_prefix>-<key>-rate-limit-failed-open`, and **one**
  `<name_prefix>-rate-limit-failed-open` alarm summing them. Same dimensionless single metric shape
  as `error_log_groups`, so the alarm count stays at one however many functions the estate holds and
  the alarm is a plain metric alarm rather than metric math.
- The log groups default to `error_log_groups`, so a consumer that already lists its functions there
  does not list them twice. `rate_limit_fail_open_log_groups` names a different set and replaces
  that list rather than merging with it.
- Sum over one 5 minute period at a threshold of 0 with `GreaterThanThreshold` and
  `notBreaching` missing data: a single fail open alarms. Actions go to the module's existing topic.
- New inputs: `rate_limit_fail_open_alarm`, `rate_limit_fail_open_log_groups`,
  `rate_limit_fail_open_filter_pattern`, `rate_limit_fail_open_metric_name`,
  `rate_limit_fail_open_alarm_threshold`, `rate_limit_fail_open_alarm_period` and
  `rate_limit_fail_open_alarm_evaluation_periods`.
- New outputs: `rate_limit_fail_open_alarm_name`, `rate_limit_fail_open_metric_filter_names` and
  `rate_limit_fail_open_metric`. The new alarm also joins `alarm_names` and `alarm_arns`.
- New test suite `modules/api-alarms/tests/rate_limit_fail_open.tftest.hcl`.

**No plan change for an existing consumer.** `rate_limit_fail_open_alarm` defaults to `false` and
nothing else in the module reads the inputs that go with it, so a consumer that upgrades without
touching its module block sees no new resources, including one that already passes
`error_log_groups`. The test suite pins that case.

Check which log shape a service emits before enabling this. The default pattern
`{ $.rate_limit_failed_open IS TRUE }` matches a **top level** JSON field, which is what a logger
given the flag as a record attribute writes. A service that interpolates
`rate_limit_failed_open=True` into its message text has no such field, and a JSON pattern cannot see
inside the message string: the metric would stay flat at 0 and the alarm would report healthy while
the limiter fails open. Those services need a substring pattern instead, and the README section
"The pattern has to match the shape the service actually logs" gives it.

## 2.3.0

`staging-access-gate`: read the region as `region` and require provider 6.x. No `api-alarms` change.

## 2.2.0

### `api-alarms`: the aggregate Lambda alarms chunk past ten functions

`lambda_function_names` no longer caps at 10 names. A CloudWatch alarm's metric math expression may
reference at most 10 metrics, which 2.1.0 enforced with a variable validation; the list is now split
into groups of at most 10 instead, in list order, and each group gets its own errors and throttles
alarm pair.

- The `lambda_function_names <= 10` validation is removed. The list has no length limit.
- The first group keeps the alarm names it has always had, `<name_prefix>-lambda-errors-aggregate`
  and `<name_prefix>-lambda-throttles-aggregate`. Groups past the first are numbered from 2:
  `<name_prefix>-lambda-errors-aggregate-2`, `-3` and so on.
- New outputs: `lambda_aggregate_errors_alarm_names`, `lambda_aggregate_throttles_alarm_names`,
  `lambda_aggregate_errors_alarm_arns`, `lambda_aggregate_throttles_alarm_arns` and
  `lambda_aggregate_function_name_chunks`. These are the outputs to build a composite alarm,
  a dashboard or a runbook on, because they stay correct as the estate grows past 10 functions.
- New test suite `modules/api-alarms/tests/lambda_aggregate_chunking.tftest.hcl`.
- New second module call in `examples/api-alarms-lambda-aggregate` showing the chunked shape.

**No plan change for an existing consumer at 10 or fewer function names.** The alarm resources
stayed on `count`, so one group is still `lambda_aggregate_errors[0]` and
`lambda_aggregate_throttles[0]`, the addresses an existing state already holds, with the same
unsuffixed alarm names and the same `m0 + m1 + ...` expression. No `moved` block is needed or
possible: `moved` requires a constant key, so a `count` index cannot be moved to a computed
`for_each` key, which is why the shape kept `count`. The 2.1.0 test suite passes unedited, and the
new suite asserts the 5 name and the exactly-10 name cases produce the 2.1.0 names at index 0.

Two things to know before growing past 10 functions:

- `lambda_aggregate_threshold` applies **within a group**, not across the estate. At the default of
  0 that is the same behavior as a single alarm. At a raised threshold it is not, because errors
  split across two groups no longer add up. An estate wanting one number for the whole thing wants
  the log based alarm in `error_log_groups`, whose metric is dimensionless.
- The order of `lambda_function_names` now decides which group a function lands in as well as its
  `m0`, `m1` id. Appending never re-chunks an earlier group, because `chunklist` fills each group
  before starting the next, so grow the list at the end rather than inserting.

`lambda_aggregate_errors_alarm_arn` and `lambda_aggregate_throttles_alarm_arn`, the singular outputs
from 2.1.0, keep their names and now report the **first** group's alarm rather than failing on a
list long enough to chunk. A consumer past 10 functions should move to the plural outputs: a
composite alarm built on the singular one would silently cover only the first ten functions.

## 2.1.0

`api-alarms`: aggregate Lambda alarms over a function per domain. `lambda_function_names` plus
`lambda_aggregate_alarm` build one `-lambda-errors-aggregate` and one `-lambda-throttles-aggregate`
metric math alarm summing every listed function, instead of a pair per function. Capped at 10 names
by the CloudWatch metric math ceiling; lifted in 2.2.0. Off by default.

## 2.0.2

Patch release.

## 2.0.1

Patch release.

## 2.0.0

`http-api`: breaking. The module takes an `integrations` map, a `routes` map and
`default_integration` instead of a single backend; per-route throttling and `cors_configuration`
were added, and the `integration_id` output was removed. `moved` blocks adopt a 1.x consumer whose
single integration is named `legacy` with zero changes.

## 1.8.0

`api-alarms`: a CloudWatch Logs metric filter alarm on the errors the application logs, through
`error_log_groups`, plus `lambda_errors_alarm_function_name`. `lambda-function`: `Image` package
type and an X-Ray write policy. New `ecr-repository` and `codeartifact` modules.

## 1.7.1

`api-alarms`: the aggregate DynamoDB throttle alarm became a single Metrics Insights query, because
PutMetricAlarm rejects an alarm holding two of them.

## 1.7.0 and earlier

See the tag messages and the GitHub releases.
