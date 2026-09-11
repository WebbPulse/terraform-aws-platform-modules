resource "aws_cloudwatch_log_metric_filter" "errors" {
  for_each = var.error_log_groups

  name           = "${var.name_prefix}-${each.key}-errors"
  log_group_name = each.value
  pattern        = var.error_filter_pattern

  metric_transformation {
    name          = local.error_metric_name
    namespace     = var.error_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "errors" {
  count = local.error_alarm_count

  alarm_name          = "${var.name_prefix}-application-errors"
  alarm_description   = "Application logged error records in ${length(var.error_log_groups)} log group${length(var.error_log_groups) == 1 ? "" : "s"}"
  namespace           = var.error_metric_namespace
  metric_name         = local.error_metric_name
  statistic           = "Sum"
  period              = var.error_alarm_period
  evaluation_periods  = var.error_alarm_evaluation_periods
  threshold           = var.error_alarm_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "standalone_lambda_errors" {
  count = local.standalone_lambda_errors_count

  alarm_name          = "${var.name_prefix}-lambda-errors"
  alarm_description   = "Lambda API reported invocation errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.lambda_errors_alarm_function_name }
  statistic           = "Sum"
  period              = var.lambda_errors_period
  evaluation_periods  = var.lambda_errors_evaluation_periods
  threshold           = var.lambda_errors_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags
}

resource "aws_cloudwatch_log_metric_filter" "rate_limit_failed_open" {
  for_each = local.rate_limit_fail_open_log_groups

  name           = "${var.name_prefix}-${each.key}-rate-limit-failed-open"
  log_group_name = each.value
  pattern        = var.rate_limit_fail_open_filter_pattern

  metric_transformation {
    name          = local.rate_limit_fail_open_metric_name
    namespace     = var.error_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "rate_limit_failed_open" {
  count = local.rate_limit_fail_open_alarm_count

  alarm_name          = "${var.name_prefix}-rate-limit-failed-open"
  alarm_description   = "The rate limiter could not reach its table and allowed requests through unchecked, in ${length(local.rate_limit_fail_open_log_groups)} log group${length(local.rate_limit_fail_open_log_groups) == 1 ? "" : "s"}"
  namespace           = var.error_metric_namespace
  metric_name         = local.rate_limit_fail_open_metric_name
  statistic           = "Sum"
  period              = var.rate_limit_fail_open_alarm_period
  evaluation_periods  = var.rate_limit_fail_open_alarm_evaluation_periods
  threshold           = var.rate_limit_fail_open_alarm_threshold
  comparison_operator = var.comparison_operator
  treat_missing_data  = var.treat_missing_data
  alarm_actions       = local.alarm_actions
  ok_actions          = local.ok_actions
  tags                = var.tags
}
