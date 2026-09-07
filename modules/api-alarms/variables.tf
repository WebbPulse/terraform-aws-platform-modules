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

# --- Lambda -------------------------------------------------------------------------------------

variable "lambda_function_name" {
  description = "Name of the Lambda function behind the API, the FunctionName dimension of the Errors and Throttles alarms. null skips both Lambda alarms."
  type        = string
  default     = null
  nullable    = true
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

# --- HTTP API -----------------------------------------------------------------------------------

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

# --- DynamoDB -----------------------------------------------------------------------------------

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
  description = "Create one <name_prefix>-dynamodb-throttles alarm covering read and write throttle events across every DynamoDB table in the account and Region, instead of, or alongside, the per table alarms from dynamodb_tables. It is built from two CloudWatch Metrics Insights queries, so it needs no table list and picks up a new table on its next evaluation. false, the default, keeps the module on the per table alarms only."
  type        = bool
  default     = false
}

variable "dynamodb_aggregate_threshold" {
  description = "Combined read plus write throttle events across all tables over one period that must be exceeded for the aggregate alarm to fire."
  type        = number
  default     = 0
}

variable "dynamodb_aggregate_period" {
  description = "Period in seconds of both Metrics Insights queries feeding the aggregate alarm. Metrics Insights alarms are standard resolution and evaluate every 60 seconds, so 60 is the only value AWS documents for them, which is why this does not default to 300 the way the per table alarms do."
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

# --- Shared alarm behaviour ---------------------------------------------------------------------

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
