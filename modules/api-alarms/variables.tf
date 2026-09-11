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

variable "lambda_function_name" {
  description = "Name of the single Lambda function behind the API, the FunctionName dimension of the per function Errors and Throttles alarms. It is the one function form of the input; an application with a function per domain passes lambda_function_names instead, and exactly one of the two forms may be set. null skips both per function Lambda alarms."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.lambda_function_name == null || length(var.lambda_function_names) == 0
    error_message = "Set lambda_function_name or lambda_function_names, not both. lambda_function_name is the one function form and creates a per function alarm pair; lambda_function_names is the many function form and feeds the aggregate alarms."
  }
}

variable "lambda_function_names" {
  description = "Names of the Lambda functions behind the API, for an application split into a function per domain. It is the many function form of lambda_function_name and exactly one of the two may be set. On its own it creates nothing: it is the list the aggregate alarms sum over, so pair it with lambda_aggregate_alarm = true. Deliberately no per function alarms, because a per function alarm pair across a growing estate is what the aggregate shape exists to avoid. There is no length limit: a CloudWatch alarm may reference at most 10 metrics, so the list is chunked into groups of at most 10 and each group gets its own alarm pair. The order is load bearing, both for the metric math ids inside a group and for which names land in which group, so build the list from a stable source and append rather than reorder."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.lambda_function_names : can(regex("^[A-Za-z0-9_-]{1,140}$", n))])
    error_message = "Every entry in lambda_function_names must be a Lambda function name: 1 to 140 characters of letters, digits, hyphens or underscores."
  }

  validation {
    condition     = length(distinct(var.lambda_function_names)) == length(var.lambda_function_names)
    error_message = "lambda_function_names must not repeat a name: each name becomes one metric_query id in the aggregate alarms."
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

variable "lambda_aggregate_alarm" {
  description = "Create a <name_prefix>-lambda-errors-aggregate alarm and a <name_prefix>-lambda-throttles-aggregate alarm summing AWS/Lambda Errors and Throttles across the functions in lambda_function_names, instead of a per function alarm pair. Each is a metric math alarm: one metric_query per function that returns no data, plus a SUM expression that does, so the alarms cover exactly the listed functions rather than every function in the account. A CloudWatch alarm may reference at most 10 metrics, so a list longer than 10 is chunked into groups of at most 10 and each group past the first gets a numbered alarm pair, -lambda-errors-aggregate-2 and so on. The alarm names carry no function name, so adding a function changes the expression on an existing alarm rather than the alarm set, until the last group fills. false, the default, creates none, which is what keeps an existing consumer byte identical."
  type        = bool
  default     = false

  validation {
    condition     = !var.lambda_aggregate_alarm || length(var.lambda_function_names) > 0
    error_message = "lambda_aggregate_alarm = true needs at least one name in lambda_function_names: the alarms sum a metric per listed function, so an empty list has nothing to sum."
  }
}

variable "lambda_aggregate_threshold" {
  description = "Sum of AWS/Lambda Errors, or of Throttles, across the functions one aggregate alarm covers over one period that must be exceeded for that alarm to fire. One threshold covers every aggregate alarm, because they all count the same kind of thing, and when lambda_function_names is long enough to chunk the threshold applies within each group rather than across the estate. The default of 0 with GreaterThanThreshold means any single error or throttle on any listed function alarms."
  type        = number
  default     = 0
}

variable "lambda_aggregate_period" {
  description = "Period in seconds of every metric feeding the aggregate Lambda alarms. CloudWatch accepts 10, 30, or any multiple of 60. The default 300 matches the per function alarms."
  type        = number
  default     = 300

  validation {
    condition     = contains([10, 30], var.lambda_aggregate_period) || (var.lambda_aggregate_period >= 60 && var.lambda_aggregate_period % 60 == 0)
    error_message = "lambda_aggregate_period must be 10, 30, or a multiple of 60."
  }
}

variable "lambda_aggregate_evaluation_periods" {
  description = "Number of periods evaluated by each aggregate Lambda alarm."
  type        = number
  default     = 1

  validation {
    condition     = var.lambda_aggregate_evaluation_periods >= 1 && floor(var.lambda_aggregate_evaluation_periods) == var.lambda_aggregate_evaluation_periods
    error_message = "lambda_aggregate_evaluation_periods must be a whole number of at least 1."
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
  description = "CloudWatch Logs filter pattern the metric filters match. The default { $.level = \"ERROR\" } matches a structured JSON record whose level field is exactly ERROR, which is what the shared observability package emits and what Lambda's own JSON log format writes. Override it to widen or narrow the match, for example { $.level = \"ERROR\" || $.level = \"CRITICAL\" }. A JSON pattern only matches log events that are valid JSON: see the README on log_format."
  type        = string
  default     = "{ $.level = \"ERROR\" }"

  validation {
    condition     = length(trimspace(var.error_filter_pattern)) > 0
    error_message = "error_filter_pattern must not be empty: an empty pattern matches every log event, which would alarm on all logging rather than on errors."
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
