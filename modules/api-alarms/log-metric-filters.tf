# --- Errors from the logs -------------------------------------------------------------------
#
# The application emits structured JSON to CloudWatch Logs and a metric filter turns the error
# records into a CloudWatch metric, which one alarm then watches. This is the errors-from-logs
# half of the observability standard: OpenTelemetry traces go to X-Ray, EMF carries metrics, and
# an error the application logged shows up here even when the invocation itself succeeded and
# AWS/Lambda Errors stays at zero.
#
# One filter per log group, one alarm for the environment. Every filter writes the same metric
# name in the same namespace with NO dimensions, which is what makes a single plain metric alarm
# the sum across all of them:
#
#   - Dimensions are part of a metric's unique identifier, so a "service" dimension would split
#     this into one series per function and a plain alarm would watch one of them rather than the
#     total. Summing them back would need metric math, and metric math tops out at 10 metrics,
#     which caps the design at 10 functions. The estate is heading for roughly 28.
#   - A metric filter with dimensions cannot also set a default value. AWS states both facts
#     directly: "If you assign dimensions to a metric created by a metric filter, you can't
#     assign a default value for that metric", and dimensions are "part of the unique identifier
#     for a metric". default_value = 0 is what keeps the metric reporting a real 0 in quiet
#     periods instead of a gap.
#
# Attribution is the trade. The alarm says the environment logged errors, not which function did;
# the filter names and the log groups themselves are where a responder looks next. That matches
# the aggregate DynamoDB alarm's trade in the same module, and it is the shape that scales to a
# function per domain.

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

# One alarm over the metric every filter above publishes to. It is an ordinary metric alarm, not
# metric math and not a Metrics Insights query, so it carries none of the limits those have: the
# Sum of a dimensionless metric is already the total of every filter writing to it, however many
# log groups error_log_groups holds.
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

# --- A Lambda Errors alarm without the rest of the Lambda alarms ------------------------------
#
# lambda_function_name creates the -lambda-errors and -lambda-throttles pair. This input is for a
# consumer that wants only the errors half, and it deliberately produces nothing when
# lambda_function_name is already set: that input's alarm has the same "<name_prefix>-lambda-errors"
# name, and two CloudWatch alarms cannot share a name in a Region. Setting both is not an error,
# it just means lambda_function_name wins and this creates nothing, so a consumer can pass both
# while migrating from one to the other without a name collision or a destroy-and-create.
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
