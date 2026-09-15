variable "name_prefix" {
  description = "Prefix for the SNS topic and for the Lambda and HTTP API alarm names, normally local.prefix, for example carmodpicker-staging. The topic is <name_prefix>-alarms and the alarms are <name_prefix>-lambda-errors, -lambda-throttles, -api-5xx and -api-integration-latency-p99. DynamoDB alarm names come from the table names instead, see dynamodb_tables."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,180}$", var.name_prefix))
    error_message = "name_prefix must be 1 to 180 characters of letters, digits, hyphens or underscores: it is used verbatim in an SNS topic name and in CloudWatch alarm names."
  }
}

variable "notification_emails" {
  description = "Email addresses subscribed to the alarm topic. Each address gets one aws_sns_topic_subscription keyed by the address itself, and AWS sends that address a confirmation email on the first apply. An address that is never confirmed leaves the subscription pending and receives nothing. An empty list creates the topic with no subscribers."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.notification_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "Every entry in notification_emails must look like an email address, for example alerts@example.com."
  }

  validation {
    condition     = length(distinct(var.notification_emails)) == length(var.notification_emails)
    error_message = "notification_emails must not repeat an address: the addresses are the for_each keys of the subscriptions."
  }
}

variable "sns_topic_name" {
  description = "Name of the alarm topic, null for <name_prefix>-alarms. Set it only to adopt a topic whose name does not follow that pattern; changing it on an existing topic replaces the topic and every subscription, which means fresh confirmation emails."
  type        = string
  default     = null
  nullable    = true
}

variable "sns_topic_tags" {
  description = "Extra tags on the SNS topic only. Tags shared with the alarms belong in tags."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to the SNS topic and every alarm. Both consumers tag through provider default_tags today and leave this empty."
  type        = map(string)
  default     = {}
}

variable "alarms" {
  description = "Which alarms the module creates, so an account can run a lean set now and turn a richer set back on later without a code change. Every key defaults to the lean set: the API 5xx alarm and the two account wide Lambda alarms on, everything else off. Set a key false to drop that alarm, and its log metric filters with it where it has any. The SNS topic and its subscriptions are never gated, so an alarm created outside this module can keep publishing to the same topic. An alarm still needs its own input as well as its toggle: api_5xx and api_integration_latency need http_api_id, application_errors and telemetry_export_errors need error_log_groups, and the toggle only ever subtracts."
  type = object({
    api_5xx                  = optional(bool, true)
    api_integration_latency  = optional(bool, false)
    lambda_account_errors    = optional(bool, true)
    lambda_account_throttles = optional(bool, true)
    application_errors       = optional(bool, false)
    rate_limit_failed_open   = optional(bool, false)
    telemetry_export_errors  = optional(bool, false)
    dynamodb_throttles       = optional(bool, false)
  })
  default = {}

  validation {
    condition     = !var.alarms.lambda_account_errors || (var.lambda_function_name == null && var.lambda_errors_alarm_function_name == null)
    error_message = "alarms.lambda_account_errors names its alarm <name_prefix>-lambda-errors, which is the same name lambda_function_name and lambda_errors_alarm_function_name give their per function alarm. Two alarms cannot share one name: set the account wide toggle false to keep the per function alarm, or drop the per function input."
  }

  validation {
    condition     = !var.alarms.lambda_account_throttles || var.lambda_function_name == null
    error_message = "alarms.lambda_account_throttles names its alarm <name_prefix>-lambda-throttles, which is the same name lambda_function_name gives its per function alarm. Set the account wide toggle false to keep the per function alarm, or drop lambda_function_name."
  }
}

variable "lambda_account_errors_threshold" {
  description = "Sum of AWS/Lambda Errors across every function in the account over one period that must be exceeded. The default of 0 with GreaterThanThreshold means any single error in the account alarms, which is the same sensitivity the per function alarms had."
  type        = number
  default     = 0
}

variable "lambda_account_errors_period" {
  description = "Period in seconds of the account wide Lambda errors alarm. CloudWatch accepts 10, 30, or any multiple of 60."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.lambda_account_errors_period) || (var.lambda_account_errors_period >= 60 && var.lambda_account_errors_period % 60 == 0)
    error_message = "lambda_account_errors_period must be 10, 30, or a multiple of 60."
  }
}

variable "lambda_account_errors_evaluation_periods" {
  description = "Number of periods evaluated by the account wide Lambda errors alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.lambda_account_errors_evaluation_periods >= 1 && floor(var.lambda_account_errors_evaluation_periods) == var.lambda_account_errors_evaluation_periods
    error_message = "lambda_account_errors_evaluation_periods must be a whole number of at least 1."
  }
}

variable "lambda_account_throttles_threshold" {
  description = "Sum of AWS/Lambda Throttles across every function in the account over one period that must be exceeded. The default of 0 with GreaterThanThreshold means any single throttle in the account alarms."
  type        = number
  default     = 0
}

variable "lambda_account_throttles_period" {
  description = "Period in seconds of the account wide Lambda throttles alarm. CloudWatch accepts 10, 30, or any multiple of 60."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.lambda_account_throttles_period) || (var.lambda_account_throttles_period >= 60 && var.lambda_account_throttles_period % 60 == 0)
    error_message = "lambda_account_throttles_period must be 10, 30, or a multiple of 60."
  }
}

variable "lambda_account_throttles_evaluation_periods" {
  description = "Number of periods evaluated by the account wide Lambda throttles alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.lambda_account_throttles_evaluation_periods >= 1 && floor(var.lambda_account_throttles_evaluation_periods) == var.lambda_account_throttles_evaluation_periods
    error_message = "lambda_account_throttles_evaluation_periods must be a whole number of at least 1."
  }
}

variable "lambda_function_name" {
  description = "Name of the single Lambda function behind the API, the FunctionName dimension of the per function Errors and Throttles alarms. null, the default, skips both. An application split into a function per domain leaves this null and uses the account wide alarms instead, which bill one metric each however many functions the account holds."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.lambda_function_name == null || can(regex("^[A-Za-z0-9_-]{1,140}$", coalesce(var.lambda_function_name, "x")))
    error_message = "lambda_function_name must be a Lambda function name: 1 to 140 characters of letters, digits, hyphens or underscores."
  }
}

variable "lambda_errors_threshold" {
  description = "Sum of AWS/Lambda Errors over one period that must be exceeded for the errors alarm to fire. The default of 0 with GreaterThanThreshold means any single error alarms."
  type        = number
  default     = 0
}

variable "lambda_errors_period" {
  description = "Period in seconds of the Lambda Errors alarm. CloudWatch accepts 10, 30, or any multiple of 60."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.lambda_errors_period) || (var.lambda_errors_period >= 60 && var.lambda_errors_period % 60 == 0)
    error_message = "lambda_errors_period must be 10, 30, or a multiple of 60."
  }
}

variable "lambda_errors_evaluation_periods" {
  description = "Number of periods evaluated by the Lambda Errors alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.lambda_errors_evaluation_periods >= 1 && floor(var.lambda_errors_evaluation_periods) == var.lambda_errors_evaluation_periods
    error_message = "lambda_errors_evaluation_periods must be a whole number of at least 1."
  }
}

variable "lambda_throttles_threshold" {
  description = "Sum of AWS/Lambda Throttles over one period that must be exceeded for the throttles alarm to fire."
  type        = number
  default     = 0
}

variable "lambda_throttles_period" {
  description = "Period in seconds of the Lambda Throttles alarm."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.lambda_throttles_period) || (var.lambda_throttles_period >= 60 && var.lambda_throttles_period % 60 == 0)
    error_message = "lambda_throttles_period must be 10, 30, or a multiple of 60."
  }
}

variable "lambda_throttles_evaluation_periods" {
  description = "Number of periods evaluated by the Lambda Throttles alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.lambda_throttles_evaluation_periods >= 1 && floor(var.lambda_throttles_evaluation_periods) == var.lambda_throttles_evaluation_periods
    error_message = "lambda_throttles_evaluation_periods must be a whole number of at least 1."
  }
}

variable "http_api_id" {
  description = "Id of the API Gateway HTTP API, the ApiId dimension of the 5xx and integration latency alarms. Pass module.api.api_id when the API comes from the http-api module. null skips both API alarms."
  type        = string
  default     = null
  nullable    = true
}

variable "api_5xx_threshold" {
  description = "Sum of AWS/ApiGateway 5xx over one period that must be exceeded for the 5xx alarm to fire."
  type        = number
  default     = 0
}

variable "api_5xx_period" {
  description = "Period in seconds of the HTTP API 5xx alarm."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.api_5xx_period) || (var.api_5xx_period >= 60 && var.api_5xx_period % 60 == 0)
    error_message = "api_5xx_period must be 10, 30, or a multiple of 60."
  }
}

variable "api_5xx_evaluation_periods" {
  description = "Number of periods evaluated by the HTTP API 5xx alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.api_5xx_evaluation_periods >= 1 && floor(var.api_5xx_evaluation_periods) == var.api_5xx_evaluation_periods
    error_message = "api_5xx_evaluation_periods must be a whole number of at least 1."
  }
}

variable "api_latency_threshold_ms" {
  description = "Integration latency in milliseconds that the chosen percentile must exceed for the latency alarm to fire. The default 10000 is ten seconds, just inside the API Gateway 30 second integration ceiling."
  type        = number
  default     = 10000

  validation {
    condition     = var.api_latency_threshold_ms > 0
    error_message = "api_latency_threshold_ms must be greater than 0."
  }
}

variable "api_latency_statistic" {
  description = "Extended statistic for the integration latency alarm, a percentile such as p95, p99 or p99.9. It is also the suffix of the alarm name, <name_prefix>-api-integration-latency-<statistic>, so changing it renames the alarm."
  type        = string
  default     = "p99"

  validation {
    condition     = can(regex("^p(100|[0-9]{1,2}(\\.[0-9]{1,2})?)$", var.api_latency_statistic))
    error_message = "api_latency_statistic must be a percentile such as p95, p99 or p99.9."
  }
}

variable "api_latency_period" {
  description = "Period in seconds of the integration latency alarm."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.api_latency_period) || (var.api_latency_period >= 60 && var.api_latency_period % 60 == 0)
    error_message = "api_latency_period must be 10, 30, or a multiple of 60."
  }
}

variable "api_latency_evaluation_periods" {
  description = "Number of periods evaluated by the integration latency alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.api_latency_evaluation_periods >= 1 && floor(var.api_latency_evaluation_periods) == var.api_latency_evaluation_periods
    error_message = "api_latency_evaluation_periods must be a whole number of at least 1."
  }
}

variable "dynamodb_tables" {
  description = "Tables to watch for read and write throttle events, as a map of for_each key to table name. The key becomes the alarm's resource address and the table name becomes the alarm name, <table name>-throttles, so a consumer adopting existing alarms keys the map exactly as its aws_dynamodb_table resource is keyed. A consumer starting fresh from a list of names can pass { for n in names : n => n }. An empty map creates no DynamoDB alarms."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for n in values(var.dynamodb_tables) : can(regex("^[A-Za-z0-9_.-]{3,235}$", n))])
    error_message = "Every value in dynamodb_tables must be a DynamoDB table name: 3 to 235 characters of letters, digits, underscore, hyphen or dot. The alarm name is that name plus -throttles."
  }
}

variable "dynamodb_throttles_threshold" {
  description = "Combined read plus write throttle events over one period that must be exceeded for a table's alarm to fire."
  type        = number
  default     = 0
}

variable "dynamodb_throttles_period" {
  description = "Period in seconds of both metrics feeding each DynamoDB throttle alarm."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.dynamodb_throttles_period) || (var.dynamodb_throttles_period >= 60 && var.dynamodb_throttles_period % 60 == 0)
    error_message = "dynamodb_throttles_period must be 10, 30, or a multiple of 60."
  }
}

variable "dynamodb_throttles_evaluation_periods" {
  description = "Number of periods evaluated by each DynamoDB throttle alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.dynamodb_throttles_evaluation_periods >= 1 && floor(var.dynamodb_throttles_evaluation_periods) == var.dynamodb_throttles_evaluation_periods
    error_message = "dynamodb_throttles_evaluation_periods must be a whole number of at least 1."
  }
}

variable "dynamodb_aggregate_alarm" {
  description = "Create one <name_prefix>-dynamodb-throttles alarm covering throttled requests across every DynamoDB table in the account and Region, instead of, or alongside, the per table alarms from dynamodb_tables. It is a CloudWatch Metrics Insights query over ThrottledRequests, so it needs no table list and picks up a new table on its next evaluation. It is not quite the same signal as the per table alarms: see the README on batch operations. false, the default, keeps the module on the per table alarms only."
  type        = bool
  default     = false
}

variable "dynamodb_aggregate_threshold" {
  description = "Throttled requests across all tables over one period that must be exceeded for the aggregate alarm to fire."
  type        = number
  default     = 0
}

variable "dynamodb_aggregate_period" {
  description = "Period in seconds of the Metrics Insights query feeding the aggregate alarm. Metrics Insights alarms are standard resolution and evaluate every 60 seconds, so 60 is the only value AWS documents for them, which is why this does not default to 300 the way the per table alarms do."
  type        = number
  default     = 60

  validation {
    condition     = var.dynamodb_aggregate_period >= 60 && var.dynamodb_aggregate_period % 60 == 0
    error_message = "dynamodb_aggregate_period must be 60 or a multiple of 60: a Metrics Insights alarm is standard resolution, so 10 and 30 are not available here."
  }
}

variable "dynamodb_aggregate_evaluation_periods" {
  description = "Number of periods evaluated by the aggregate DynamoDB throttle alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.dynamodb_aggregate_evaluation_periods >= 1 && floor(var.dynamodb_aggregate_evaluation_periods) == var.dynamodb_aggregate_evaluation_periods
    error_message = "dynamodb_aggregate_evaluation_periods must be a whole number of at least 1."
  }
}

variable "error_log_groups" {
  description = "CloudWatch log groups to watch for structured error records, as a map of short name to log group name. The key is the for_each key and goes into the filter name, <name_prefix>-<key>-errors, so it should be the domain or service the function serves, for example \"posts\" or \"users\". The value is the full log group name, normally /aws/lambda/<function name>. Every filter publishes to one shared metric with no dimensions, so however many log groups this holds there is still exactly one alarm summing them. An empty map, the default, creates no filters and no alarm, which is why an existing consumer sees no diff."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.error_log_groups) : can(regex("^[A-Za-z0-9_-]{1,64}$", k))])
    error_message = "Every key in error_log_groups must be 1 to 64 characters of letters, digits, hyphens or underscores: it is used verbatim in the metric filter name."
  }

  validation {
    condition     = alltrue([for n in values(var.error_log_groups) : can(regex("^[A-Za-z0-9_./#-]{1,512}$", n))])
    error_message = "Every value in error_log_groups must be a CloudWatch log group name, for example /aws/lambda/my-function."
  }
}

variable "error_filter_pattern" {
  description = "CloudWatch Logs filter pattern the error metric filters match. null, the default, builds the pattern from error_excluded_loggers: a record whose level is exactly ERROR, whose logger is none of the excluded ones, and, so that coverage never narrows, any ERROR record carrying no logger field at all. Set it to a literal pattern to take the match over completely, in which case error_excluded_loggers no longer affects it and only the telemetry filter still reads the list. A JSON pattern only matches log events that are valid JSON: see the README on log_format."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.error_filter_pattern == null || length(trimspace(coalesce(var.error_filter_pattern, ""))) > 0
    error_message = "error_filter_pattern must not be empty: an empty pattern matches every log event, which would alarm on all logging rather than on errors. Pass null to use the pattern the module builds."
  }
}

variable "error_excluded_loggers" {
  description = "Logger names whose ERROR records are telemetry pipeline failures rather than application faults, so they must not reach the application errors alarm. The span exporter 403s and times out against the X-Ray OTLP endpoint on a Lambda sandbox teardown, which is a dropped trace and not a failed request, and at a zero threshold one of those puts the alarm into ALARM. These names are excluded from error_filter_pattern and are exactly the set the telemetry export errors alarm counts instead, so a name moved out of this list moves the records back onto the application alarm rather than losing them. An empty list excludes nothing and leaves the error pattern matching every ERROR record."
  type        = list(string)
  default = [
    "opentelemetry.exporter.otlp.proto.http.trace_exporter",
    "opentelemetry.sdk.trace.export",
    "webbpulse.otel",
  ]

  validation {
    condition     = alltrue([for l in var.error_excluded_loggers : can(regex("^[A-Za-z0-9_.-]{1,256}$", l))])
    error_message = "Every entry in error_excluded_loggers must be 1 to 256 characters of letters, digits, dots, hyphens or underscores: it is interpolated into a CloudWatch Logs filter pattern as a quoted string."
  }

  validation {
    condition     = length(var.error_excluded_loggers) == length(distinct(var.error_excluded_loggers))
    error_message = "error_excluded_loggers must not repeat a logger name."
  }
}

variable "telemetry_alarm_enabled" {
  description = "Create one <name_prefix>-telemetry-export-errors alarm over the metric filters that count the excluded loggers' ERROR records. true, the default, keeps the telemetry failures visible after they stop paging as application errors: a handful an hour is the normal teardown drop, so the threshold is a rate rather than a single record. false creates no telemetry filters and no alarm, which silences the pipeline entirely. It needs a non-empty error_excluded_loggers to have anything to match."
  type        = bool
  default     = true
}

variable "telemetry_alarm_threshold" {
  description = "Number of telemetry export error records in one period that must be exceeded before the telemetry alarm fires. The default 20 over an hour sits above the steady trickle of teardown drops and below a pipeline that has genuinely stopped delivering."
  type        = number
  default     = 20

  validation {
    condition     = var.telemetry_alarm_threshold >= 0
    error_message = "telemetry_alarm_threshold must not be negative."
  }
}

variable "telemetry_alarm_period" {
  description = "Period in seconds of the telemetry export errors alarm. CloudWatch accepts 10, 30, or any multiple of 60. The default 3600 makes the threshold an hourly rate."
  type        = number
  default     = 3600

  validation {
    condition     = contains([10, 30], var.telemetry_alarm_period) || (var.telemetry_alarm_period >= 60 && var.telemetry_alarm_period % 60 == 0)
    error_message = "telemetry_alarm_period must be 10, 30, or a multiple of 60."
  }
}

variable "telemetry_alarm_evaluation_periods" {
  description = "Number of periods evaluated by the telemetry export errors alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.telemetry_alarm_evaluation_periods >= 1 && floor(var.telemetry_alarm_evaluation_periods) == var.telemetry_alarm_evaluation_periods
    error_message = "telemetry_alarm_evaluation_periods must be a whole number of at least 1."
  }
}

variable "telemetry_metric_name" {
  description = "Name of the metric every telemetry filter publishes to, null for <name_prefix>-telemetry-export-errors. It is a separate series from the application errors metric, which is the whole point: the two are counted apart so one can page and the other only inform."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.telemetry_metric_name == null || can(regex("^[^:*$]{1,255}$", coalesce(var.telemetry_metric_name, "x")))
    error_message = "telemetry_metric_name must be 1 to 255 characters and must not contain :, * or $."
  }
}

variable "error_metric_namespace" {
  description = "CloudWatch namespace the error metric is published in. It is a custom namespace, so it must not start with AWS/. One namespace across every application keeps the metric findable in the console."
  type        = string
  default     = "WebbPulse/Application"

  validation {
    condition     = can(regex("^[^:*$]{1,255}$", var.error_metric_namespace)) && !startswith(var.error_metric_namespace, "AWS/")
    error_message = "error_metric_namespace must be 1 to 255 characters without :, * or $, and must not start with AWS/ because that prefix is reserved for AWS service namespaces."
  }
}

variable "error_metric_name" {
  description = "Name of the metric every filter publishes to, null for <name_prefix>-application-errors. Every log group in error_log_groups writes this one metric with no dimensions, so the alarm's Sum is the total across all of them. Two environments in one account must not share a name, which is why the default carries name_prefix."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.error_metric_name == null || can(regex("^[^:*$]{1,255}$", coalesce(var.error_metric_name, "x")))
    error_message = "error_metric_name must be 1 to 255 characters and must not contain :, * or $."
  }
}

variable "error_alarm_threshold" {
  description = "Number of error records across every watched log group in one period that must be exceeded for the alarm to fire. The default of 0 with GreaterThanThreshold means any single logged error alarms, matching the Lambda Errors alarm. Raise it if the application logs expected errors."
  type        = number
  default     = 0
}

variable "error_alarm_period" {
  description = "Period in seconds of the application errors alarm. CloudWatch accepts 10, 30, or any multiple of 60. The default 300 matches the rest of the module."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.error_alarm_period) || (var.error_alarm_period >= 60 && var.error_alarm_period % 60 == 0)
    error_message = "error_alarm_period must be 10, 30, or a multiple of 60."
  }
}

variable "error_alarm_evaluation_periods" {
  description = "Number of periods evaluated by the application errors alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.error_alarm_evaluation_periods >= 1 && floor(var.error_alarm_evaluation_periods) == var.error_alarm_evaluation_periods
    error_message = "error_alarm_evaluation_periods must be a whole number of at least 1."
  }
}

variable "lambda_errors_alarm_function_name" {
  description = "Create a <name_prefix>-lambda-errors alarm on this function without also creating the throttles alarm that lambda_function_name brings. It is for a consumer that wants the errors alarm on its own, alongside the log based alarm above. It is ignored when lambda_function_name is set, because that input already creates an alarm of exactly that name and two alarms cannot share a name in a Region; setting both is therefore safe rather than a conflict. It reuses lambda_errors_threshold, lambda_errors_period and lambda_errors_evaluation_periods. null, the default, creates nothing."
  type        = string
  default     = null
  nullable    = true
}

variable "comparison_operator" {
  description = "Comparison operator on every alarm in the module. The thresholds are all upper bounds, so GreaterThanThreshold is the sensible value."
  type        = string
  default     = "GreaterThanThreshold"

  validation {
    condition     = contains(["GreaterThanThreshold", "GreaterThanOrEqualToThreshold", "LessThanThreshold", "LessThanOrEqualToThreshold"], var.comparison_operator)
    error_message = "comparison_operator must be one of GreaterThanThreshold, GreaterThanOrEqualToThreshold, LessThanThreshold or LessThanOrEqualToThreshold."
  }
}

variable "treat_missing_data" {
  description = "How every alarm treats a period with no datapoints. notBreaching keeps a quiet API out of alarm, which is what both consumers want."
  type        = string
  default     = "notBreaching"

  validation {
    condition     = contains(["missing", "ignore", "breaching", "notBreaching"], var.treat_missing_data)
    error_message = "treat_missing_data must be one of missing, ignore, breaching or notBreaching."
  }
}

variable "notify_on_ok" {
  description = "Send the topic an OK notification as well as an ALARM notification. true puts the topic ARN in ok_actions on every alarm, which is what both consumers do today; false leaves ok_actions empty so the topic only carries alarms."
  type        = bool
  default     = true
}

variable "extra_alarm_actions" {
  description = "Additional action ARNs added to alarm_actions on every alarm, alongside the module's own topic. Use it to also page a Chatbot or an incident tool without giving up the email topic."
  type        = list(string)
  default     = []
}

variable "rate_limit_fail_open_alarm" {
  description = "Create one <name_prefix>-rate-limit-failed-open alarm over the metric filters that count the rate limiter's fail open WARNINGs. false, the default, creates no filters and no alarm, which is why an existing consumer sees no diff. The limiter allows a request when it cannot reach its table, so this alarm is the compensating control that says the limit was not being enforced."
  type        = bool
  default     = false
}

variable "rate_limit_fail_open_log_groups" {
  description = "Log groups to watch for the limiter's fail open records, as a map of short name to log group name, exactly like error_log_groups. null, the default, reuses error_log_groups, which is what a consumer running the limiter in every function it already watches for errors wants. Set it to name a different set; it replaces the error_log_groups list rather than merging with it. The key goes into the filter name, <name_prefix>-<key>-rate-limit-failed-open."
  type        = map(string)
  default     = null
  nullable    = true

  validation {
    condition     = var.rate_limit_fail_open_log_groups == null || alltrue([for k in keys(coalesce(var.rate_limit_fail_open_log_groups, {})) : can(regex("^[A-Za-z0-9_-]{1,64}$", k))])
    error_message = "Every key in rate_limit_fail_open_log_groups must be 1 to 64 characters of letters, digits, hyphens or underscores: it is used verbatim in the metric filter name."
  }

  validation {
    condition     = var.rate_limit_fail_open_log_groups == null || alltrue([for n in values(coalesce(var.rate_limit_fail_open_log_groups, {})) : can(regex("^[A-Za-z0-9_./#-]{1,512}$", n))])
    error_message = "Every value in rate_limit_fail_open_log_groups must be a CloudWatch log group name, for example /aws/lambda/my-function."
  }
}

variable "rate_limit_fail_open_filter_pattern" {
  description = "CloudWatch Logs filter pattern the fail open metric filters match. The default { $.rate_limit_failed_open IS TRUE } matches a structured JSON record carrying a top level rate_limit_failed_open field whose value is the JSON boolean true. That is what a logger emitting the field as a log record attribute writes. A service that instead interpolates the field into the message text needs a substring pattern such as \"rate_limit_failed_open=True\" here, because a JSON pattern cannot see inside the message string: see the README on which shape a service emits."
  type        = string
  default     = "{ $.rate_limit_failed_open IS TRUE }"

  validation {
    condition     = length(trimspace(var.rate_limit_fail_open_filter_pattern)) > 0
    error_message = "rate_limit_fail_open_filter_pattern must not be empty: an empty pattern matches every log event, which would alarm on all logging rather than on the limiter failing open."
  }
}

variable "rate_limit_fail_open_metric_name" {
  description = "Name of the metric every fail open filter publishes to, null for <name_prefix>-rate-limit-failed-open. Every log group writes this one metric with no dimensions, so the alarm's Sum is the total across all of them. It is deliberately a different metric from the application errors one: a fail open is a request that went through unprotected, not a request that went wrong, and the two want separate thresholds."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.rate_limit_fail_open_metric_name == null || can(regex("^[^:*$]{1,255}$", coalesce(var.rate_limit_fail_open_metric_name, "x")))
    error_message = "rate_limit_fail_open_metric_name must be 1 to 255 characters and must not contain :, * or $."
  }
}

variable "rate_limit_fail_open_alarm_threshold" {
  description = "Fail open records across every watched log group in one period that must be exceeded for the alarm to fire. The default of 0 with GreaterThanThreshold means a single fail open alarms, which is the right sensitivity for a control that is meant never to fail: the interesting event is that it happened at all."
  type        = number
  default     = 0
}

variable "rate_limit_fail_open_alarm_period" {
  description = "Period in seconds of the rate limit fail open alarm. CloudWatch accepts 10, 30, or any multiple of 60. The default 300 matches the rest of the module."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.rate_limit_fail_open_alarm_period) || (var.rate_limit_fail_open_alarm_period >= 60 && var.rate_limit_fail_open_alarm_period % 60 == 0)
    error_message = "rate_limit_fail_open_alarm_period must be 10, 30, or a multiple of 60."
  }
}

variable "rate_limit_fail_open_alarm_evaluation_periods" {
  description = "Number of periods evaluated by the rate limit fail open alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.rate_limit_fail_open_alarm_evaluation_periods >= 1 && floor(var.rate_limit_fail_open_alarm_evaluation_periods) == var.rate_limit_fail_open_alarm_evaluation_periods
    error_message = "rate_limit_fail_open_alarm_evaluation_periods must be a whole number of at least 1."
  }
}
