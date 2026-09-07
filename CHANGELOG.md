# Changelog

One tag covers every submodule in this repository, so this file is per release, not per module.
Each entry names the modules a release touched. Releases before 2.2.0 were documented in their tag
messages and on the GitHub release; they are summarised here from those, and the tag message stays
the authoritative record for them.

Consumers pin `~> MAJOR.MINOR` and pick up later minors on their next plan, so an entry marked
**no plan change** is one an existing consumer can take without reviewing a diff.

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
