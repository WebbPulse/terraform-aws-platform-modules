locals {
  topic_name = coalesce(var.sns_topic_name, "${var.name_prefix}-alarms")

  # The addresses are the for_each keys, so a removed address destroys only its own subscription.
  subscriptions = { for e in var.notification_emails : e => e }

  lambda_count = var.lambda_function_name == null ? 0 : 1
  api_count    = var.http_api_id == null ? 0 : 1

  # The aggregate Lambda alarms exist only when asked for, and the variable's own validation makes
  # lambda_function_names non-empty whenever they do.
  #
  # A CloudWatch alarm's metric math expression may reference at most 10 metrics, so a list longer
  # than 10 cannot be one alarm. It is chunked instead: groups of at most 10 names, in list order,
  # one errors alarm and one throttles alarm per group. Chunking rather than capping is what lets
  # an estate grow past 10 functions and still get the aggregate shape.
  #
  # chunklist preserves order and fills each group before starting the next, so the first 10 names
  # are always group 0, the next 10 group 1, and appending a name only ever changes the last group
  # or adds one. A list of 10 or fewer is one group, which is exactly what v2.1.0 built.
  lambda_aggregate_chunk_size = 10

  lambda_aggregate_chunks = var.lambda_aggregate_alarm ? chunklist(var.lambda_function_names, local.lambda_aggregate_chunk_size) : []

  # The resources stay on count, indexed by chunk, rather than moving to for_each. That is the
  # whole backward compatibility story: a consumer with 10 or fewer functions gets exactly one
  # chunk, so the addresses are still lambda_aggregate_errors[0] and lambda_aggregate_throttles[0]
  # and the plan is empty. No moved block is needed, and none would help: a count index cannot be
  # moved to a for_each key by an expression anyway.
  lambda_aggregate_count = length(local.lambda_aggregate_chunks)

  # A metric math id must start with a lowercase letter and hold only letters, digits and
  # underscores, which a function name does not: it may contain hyphens, and two different
  # functions could differ only by a character the id cannot carry. So the id is positional,
  # "m0", "m1" and so on, and the function name rides in the metric_query label instead, where
  # CloudWatch shows it on the alarm graph and in the notification. Positional ids are stable as
  # long as the list order is, which is why the input is a list rather than a set.
  #
  # The ids restart at m0 in every chunk. They are scoped to the alarm they appear in, so there is
  # no need to carry a global offset, and restarting keeps a chunk's expression identical to what
  # the same 10 names produced as a whole list under v2.1.0.
  lambda_aggregate_metrics = [
    for chunk in local.lambda_aggregate_chunks : {
      for i, name in chunk : "m${i}" => name
    }
  ]

  # "m0 + m1 + m2" over the ids above, built from the list rather than from keys() so the order is
  # the input's order and not a lexicographic accident. One expression string per chunk is shared
  # by that chunk's two alarms, because both sum the same set of functions on a different metric.
  lambda_aggregate_expressions = [
    for chunk in local.lambda_aggregate_chunks : join(" + ", [for i, _ in chunk : "m${i}"])
  ]

  # Group 0 keeps the unsuffixed names v2.1.0 created, so a consumer at 10 or fewer functions keeps
  # its alarm names as well as its addresses. Later groups are numbered from 2, which reads as
  # "the second group" on a dashboard rather than as an index.
  lambda_aggregate_name_suffixes = [
    for i, _ in local.lambda_aggregate_chunks : i == 0 ? "" : "-${i + 1}"
  ]

  # Every filter in error_log_groups publishes to this one metric, with no dimensions, so the
  # alarm below is a plain metric alarm whose Sum is the total across all of them. See the README
  # section "Errors from the logs" for why the metric carries no dimensions.
  error_metric_name = coalesce(var.error_metric_name, "${var.name_prefix}-application-errors")

  # The alarm exists only when there is at least one log group to feed it. An empty map is the
  # default, which is what keeps the feature off for consumers that pass nothing.
  error_alarm_count = length(var.error_log_groups) > 0 ? 1 : 0

  # The Lambda Errors alarm already exists whenever lambda_function_name is set, so this second
  # input only has something to create when the module was not given a function name. That keeps
  # "<name_prefix>-lambda-errors" a single resource with a single name, whichever input asked
  # for it, rather than two resources racing for the same alarm name.
  standalone_lambda_errors_count = var.lambda_errors_alarm_function_name != null && var.lambda_function_name == null ? 1 : 0

  # The fail open filters watch the same functions the error filters do, so the log groups default
  # to error_log_groups rather than being listed twice. A consumer whose limiter runs in only some
  # of those functions overrides the list with rate_limit_fail_open_log_groups; the override is a
  # full replacement, not a merge, so it can also name a log group the error filters do not watch.
  rate_limit_fail_open_log_groups = (
    var.rate_limit_fail_open_alarm
    ? (var.rate_limit_fail_open_log_groups == null ? var.error_log_groups : var.rate_limit_fail_open_log_groups)
    : {}
  )

  # Same dimensionless single metric shape as the error metric above, and the same reason for
  # carrying name_prefix: two environments in one account must not share a metric name.
  rate_limit_fail_open_metric_name = coalesce(var.rate_limit_fail_open_metric_name, "${var.name_prefix}-rate-limit-failed-open")

  # The alarm needs both the switch and something to watch. Turning the switch on with no log
  # groups to resolve creates neither filters nor an alarm rather than an alarm that can never
  # leave INSUFFICIENT_DATA.
  rate_limit_fail_open_alarm_count = length(local.rate_limit_fail_open_log_groups) > 0 ? 1 : 0

  alarm_actions = concat([aws_sns_topic.alarms.arn], var.extra_alarm_actions)
  ok_actions    = var.notify_on_ok ? [aws_sns_topic.alarms.arn] : []

  # Rendered into the latency alarm description. 10000 ms reads as "10 s", 1500 ms as "1.5 s".
  latency_threshold_seconds = format("%g", var.api_latency_threshold_ms / 1000)
}
