variable "name_prefix" {
  description = "Prefix for the CloudWatch Logs resource policy name, usually the application's <product>-<environment> prefix."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.name_prefix))
    error_message = "name_prefix must be alphanumeric with dots, dashes or underscores, and must not start with a separator."
  }
}

variable "resource_policy_name_suffix" {
  description = "Appended to name_prefix to name the CloudWatch Logs resource policy X-Ray writes spans under."
  type        = string
  default     = "-transaction-search-spans"
}

variable "adopt_spans_log_group" {
  description = "Adopt the reserved aws/spans log group into state and hold it at spans_log_group_retention_in_days. X-Ray creates that group itself the first time it writes a span to the CloudWatchLogs destination, and it cannot be created ahead of time because CreateLogGroup rejects names beginning with aws/. An import block whose target does not exist is a plan time error, so a brand new account applies once with this false, generates one span, then sets it true."
  type        = bool
  default     = false
}

variable "spans_log_group_name" {
  description = "Reserved log group X-Ray writes spans to. Only change this if AWS changes the reserved name."
  type        = string
  default     = "aws/spans"
}

variable "spans_log_group_retention_in_days" {
  description = "Retention held on the adopted spans log group. Ignored when adopt_spans_log_group is false."
  type        = number
  default     = 7
}

variable "application_signals_log_group_name" {
  description = "Second log group named in the resource policy, which Application Signals writes to. Set to null to leave it out of the policy."
  type        = string
  default     = "/aws/application-signals/data"
  nullable    = true
}

variable "create_indexing_rule" {
  description = "Manage the account's Default X-Ray indexing rule. One rule named Default exists per account and region whether or not Terraform manages it."
  type        = bool
  default     = true
}

variable "indexing_rule_sampling_percentage" {
  description = "Percentage of traces the Default indexing rule indexes for Transaction Search, 0 to 100. Indexed spans are billed, so the platform default is the free tier's 1 percent."
  type        = number
  default     = 1

  validation {
    condition     = var.indexing_rule_sampling_percentage >= 0 && var.indexing_rule_sampling_percentage <= 100
    error_message = "indexing_rule_sampling_percentage must be between 0 and 100."
  }
}

variable "tags" {
  description = "Tags on the adopted spans log group."
  type        = map(string)
  default     = {}
}
