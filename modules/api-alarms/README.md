# terraform-aws-api-alarms

The alarm set for a Lambda-backed HTTP API on DynamoDB: one SNS topic with email subscribers,
Lambda, HTTP API, DynamoDB and CloudWatch Logs metric filter alarms all publishing to it.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms`.

## Usage

```hcl
module "alarms" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/api-alarms"
  version = "~> 1.7"

  name_prefix         = local.prefix
  notification_emails = ["alerts@example.com"]

  lambda_function_name = module.lambda_api.function_name
  http_api_id          = module.api.api_id

  dynamodb_aggregate_alarm = true
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name_prefix` | Prefix for the topic and the Lambda and API alarm names | required |
| `notification_emails` | Addresses subscribed to the topic; each gets a confirmation email | `[]` |
| `sns_topic_name` | Topic name, null for `<name_prefix>-alarms` | `null` |
| `sns_topic_tags` | Extra tags on the topic only | `{}` |
| `tags` | Tags on the topic and every alarm | `{}` |
| `lambda_function_name` | One function form: `FunctionName` of the per function alarm pair; null skips both | `null` |
| `lambda_function_names` | Many function form: the functions the aggregate alarms sum over; creates nothing alone | `[]` |
| `lambda_errors_threshold` | Sum of `Errors` per period that must be exceeded | `0` |
| `lambda_errors_period` | Period in seconds | `300` |
| `lambda_errors_evaluation_periods` | Periods evaluated | `1` |
| `lambda_throttles_threshold` | Sum of `Throttles` per period that must be exceeded | `0` |
| `lambda_throttles_period` | Period in seconds | `300` |
| `lambda_throttles_evaluation_periods` | Periods evaluated | `1` |
| `lambda_aggregate_alarm` | Create the aggregate errors and throttles pair summing `lambda_function_names` | `false` |
| `lambda_aggregate_threshold` | Errors, or throttles, summed across the functions one aggregate alarm covers | `0` |
| `lambda_aggregate_period` | Period in seconds of every metric feeding the aggregate alarms | `300` |
| `lambda_aggregate_evaluation_periods` | Periods evaluated by each aggregate alarm | `1` |
| `http_api_id` | `ApiId` dimension of the API alarms; null skips both | `null` |
| `api_5xx_threshold` | Sum of `5xx` per period that must be exceeded | `0` |
| `api_5xx_period` | Period in seconds | `300` |
| `api_5xx_evaluation_periods` | Periods evaluated | `1` |
| `api_latency_threshold_ms` | Integration latency in milliseconds the percentile must exceed | `10000` |
| `api_latency_statistic` | Percentile for the latency alarm; also the alarm name suffix | `"p99"` |
| `api_latency_period` | Period in seconds | `300` |
| `api_latency_evaluation_periods` | Periods evaluated | `1` |
| `dynamodb_tables` | Tables to watch, map of `for_each` key to table name | `{}` |
| `dynamodb_throttles_threshold` | Read plus write throttle events per period to exceed | `0` |
| `dynamodb_throttles_period` | Period in seconds of both metrics | `300` |
| `dynamodb_throttles_evaluation_periods` | Periods evaluated | `1` |
| `dynamodb_aggregate_alarm` | Create one `<name_prefix>-dynamodb-throttles` alarm over every table | `false` |
| `dynamodb_aggregate_threshold` | Throttled requests across all tables per period to exceed | `0` |
| `dynamodb_aggregate_period` | Period in seconds of the Metrics Insights query | `60` |
| `dynamodb_aggregate_evaluation_periods` | Periods evaluated | `1` |
| `error_log_groups` | Log groups to watch for JSON error records, map of short name to log group name | `{}` |
| `error_filter_pattern` | Pattern the error filters match; null builds it from `error_excluded_loggers` | `null` |
| `error_excluded_loggers` | Loggers whose ERROR records are telemetry failures, not application faults | `["opentelemetry.exporter.otlp.proto.http.trace_exporter", "opentelemetry.sdk.trace.export", "webbpulse.otel"]` |
| `telemetry_alarm_enabled` | Create one `<name_prefix>-telemetry-export-errors` alarm over those records | `true` |
| `telemetry_alarm_threshold` | Telemetry export error records in one period that must be exceeded | `20` |
| `telemetry_alarm_period` | Period in seconds of the telemetry alarm | `3600` |
| `telemetry_alarm_evaluation_periods` | Periods evaluated by the telemetry alarm | `1` |
| `telemetry_metric_name` | Metric the telemetry filters publish to, null for `<name_prefix>-telemetry-export-errors` | `null` |
| `error_metric_namespace` | Custom namespace for the log metrics; must not start with `AWS/` | `"WebbPulse/Application"` |
| `error_metric_name` | Metric every error filter publishes to, null for `<name_prefix>-application-errors` | `null` |
| `error_alarm_threshold` | Error records across every watched log group per period to exceed | `0` |
| `error_alarm_period` | Period in seconds | `300` |
| `error_alarm_evaluation_periods` | Periods evaluated | `1` |
| `lambda_errors_alarm_function_name` | Create only the `-lambda-errors` alarm on this function | `null` |
| `comparison_operator` | Comparison on every alarm | `"GreaterThanThreshold"` |
| `treat_missing_data` | Missing data handling on every alarm | `"notBreaching"` |
| `notify_on_ok` | Put the topic in `ok_actions` as well as `alarm_actions` | `true` |
| `extra_alarm_actions` | Extra action ARNs on every alarm, alongside the topic | `[]` |
| `rate_limit_fail_open_alarm` | Create one `<name_prefix>-rate-limit-failed-open` alarm | `false` |
| `rate_limit_fail_open_log_groups` | Log groups to watch for fail open records; null reuses `error_log_groups` | `null` |
| `rate_limit_fail_open_filter_pattern` | Pattern the fail open filters match | `"{ $.rate_limit_failed_open IS TRUE }"` |
| `rate_limit_fail_open_metric_name` | Metric the fail open filters publish to, null for `<name_prefix>-rate-limit-failed-open` | `null` |
| `rate_limit_fail_open_alarm_threshold` | Fail open records across every watched log group per period to exceed | `0` |
| `rate_limit_fail_open_alarm_period` | Period in seconds | `300` |
| `rate_limit_fail_open_alarm_evaluation_periods` | Periods evaluated | `1` |

## Outputs

| Name | Description |
| --- | --- |
| `sns_topic_arn` | ARN of the alarm topic |
| `sns_topic_name` | Name of the alarm topic |
| `subscription_arns` | Email subscription ARNs keyed by address |
| `alarm_names` | Every alarm name the module created, sorted |
| `alarm_arns` | Every alarm ARN the module created, sorted |
| `lambda_alarm_names` | Every `AWS/Lambda` alarm name created, empty when no function input is set |
| `lambda_aggregate_alarm_names` | Every aggregate alarm name, errors first then throttles, each in chunk order |
| `lambda_aggregate_alarm_arns` | Every aggregate alarm ARN, errors first then throttles, each in chunk order |
| `lambda_aggregate_errors_alarm_arn` | ARN of the first aggregate errors alarm, `null` when it is off |
| `lambda_aggregate_throttles_alarm_arn` | ARN of the first aggregate throttles alarm, `null` when it is off |
| `lambda_aggregate_errors_alarm_arns` | ARNs of every aggregate errors alarm, one per group, in chunk order |
| `lambda_aggregate_throttles_alarm_arns` | ARNs of every aggregate throttles alarm, one per group, in chunk order |
| `lambda_aggregate_errors_alarm_names` | Names of every aggregate errors alarm, one per group, in chunk order |
| `lambda_aggregate_throttles_alarm_names` | Names of every aggregate throttles alarm, one per group, in chunk order |
| `lambda_aggregate_function_name_chunks` | The function names as the module grouped them, one list per alarm pair |
| `api_alarm_names` | The two HTTP API alarm names, empty when `http_api_id` is null |
| `dynamodb_alarm_names` | Table alarm names keyed by their `dynamodb_tables` key |
| `dynamodb_aggregate_alarm_name` | Name of the aggregate DynamoDB alarm, `null` when it is off |
| `error_alarm_name` | Name of the application errors alarm, `null` when `error_log_groups` is empty |
| `error_metric_filter_names` | Error metric filter names keyed by their `error_log_groups` key |
| `error_metric` | `{ namespace, name }` of the metric the error filters publish to |
| `error_filter_pattern` | The pattern the error filters were created with, built or supplied |
| `telemetry_alarm_name` | Name of the telemetry export errors alarm, `null` when it is off |
| `telemetry_metric_filter_names` | Telemetry filter names keyed by their `error_log_groups` key |
| `telemetry_metric` | `{ namespace, name }` of the metric the telemetry filters publish to |
| `rate_limit_fail_open_alarm_name` | Name of the rate limit fail open alarm, `null` when it is off |
| `rate_limit_fail_open_metric_filter_names` | Fail open metric filter names keyed by their log group key |
| `rate_limit_fail_open_metric` | `{ namespace, name }` of the metric the fail open filters publish to |

## Gotchas

- Application errors from the logs and telemetry export failures are counted as two separate
  metrics: the loggers in `error_excluded_loggers` are cut out of the application errors pattern and
  land on the `-telemetry-export-errors` alarm instead, so a dropped trace never pages as a fault.
- `lambda_function_name` and `lambda_function_names` are mutually exclusive, and a plan setting both
  is rejected by a variable validation rather than silently preferring one.
- `lambda_aggregate_alarm = true` needs a non-empty `lambda_function_names`, and the list is chunked
  into groups of at most 10, so past 10 names use the plural `_arns` outputs, not the singular ones.
- `dynamodb_aggregate_period` must be 60 or a multiple of 60: a Metrics Insights alarm is standard
  resolution, so the 10 and 30 second periods the other alarms accept are rejected here.
- Every email subscription needs an out of band confirmation click; until then it stays
  `PendingConfirmation` and delivers nothing. Changing an address destroys and recreates the
  subscription, which sends a fresh confirmation email.
- Changing `sns_topic_name` on an existing topic replaces the topic and every subscription.
- `lambda_errors_alarm_function_name` is ignored when `lambda_function_name` is set, because that
  input already creates an alarm of exactly that name and two alarms cannot share one.
- `api_latency_statistic` is the alarm name suffix, so changing it renames and therefore replaces
  the latency alarm.
- `error_filter_pattern` and `rate_limit_fail_open_filter_pattern` must not be empty: an empty
  pattern matches every log event. Pass `null` to `error_filter_pattern` for the built pattern.
- Setting `error_filter_pattern` to a literal takes the match over completely and
  `error_excluded_loggers` no longer shapes it, though it still drives the telemetry filters.
- `rate_limit_fail_open_log_groups` replaces `error_log_groups` rather than merging with it.
- Two environments in one account must not share `error_metric_name` or `telemetry_metric_name`;
  the defaults carry `name_prefix` for that reason.
