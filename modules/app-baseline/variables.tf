variable "name" {
  description = "Base name for every resource the module creates: the resource group, the anomaly monitor and subscription all take it verbatim, and each budget is named \"<name>-<suffix>\". Both application estates pass local.prefix, for example carmodpicker-production."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]{1,120}$", var.name))
    error_message = "name must be 1 to 120 characters of letters, digits, period, underscore or hyphen. Resource group names and budget names share this character set, and the budget suffix is appended to it."
  }
}

variable "notification_emails" {
  description = "Addresses that receive the cost anomaly digest and every budget alert. Order matters: it is the order the subscriber blocks and the subscriber_email_addresses list are written in, so keep the order the estate already has to plan clean."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for email in var.notification_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", email))])
    error_message = "Every entry in notification_emails must look like an email address. AWS rejects anything else at apply time, and an anomaly subscription with no valid subscriber never sends."
  }

  validation {
    condition     = length(var.notification_emails) == length(distinct(var.notification_emails))
    error_message = "notification_emails must not repeat an address. Cost Explorer rejects a subscription with duplicate subscribers."
  }
}

variable "resource_group_enabled" {
  description = "Create the tag based resource group. false makes that part of the module a no-op, for an account that already groups its resources some other way."
  type        = bool
  default     = true
}

variable "resource_group_description" {
  description = "Description stored on the resource group. null leaves the argument unset, which is what a group created without a description carries."
  type        = string
  default     = null
  nullable    = true
}

variable "resource_group_tag_filters" {
  description = "Tag key to accepted values, rendered into the group's TagFilters. The default groups everything carrying Project = <name>, which is almost never what an estate wants because name includes the environment; pass { Project = [\"carmodpicker\"] } to match the project tag alone."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = !var.resource_group_enabled || length(var.resource_group_tag_filters) > 0
    error_message = "resource_group_tag_filters must name at least one tag when resource_group_enabled is true. A group with no filters matches nothing."
  }

  validation {
    condition     = alltrue([for values in var.resource_group_tag_filters : length(values) > 0])
    error_message = "Every tag key in resource_group_tag_filters must list at least one accepted value."
  }
}

variable "resource_group_resource_type_filters" {
  description = "ResourceTypeFilters in the group's query. The default matches every taggable service, which is what a project wide group wants."
  type        = list(string)
  default     = ["AWS::AllSupported"]

  validation {
    condition     = length(var.resource_group_resource_type_filters) > 0
    error_message = "resource_group_resource_type_filters must hold at least one entry. AWS::AllSupported is the catch all."
  }
}

variable "anomaly_detection_enabled" {
  description = "Create the Cost Explorer anomaly monitor and its subscription. Cost anomaly detection is free, so the only reason to turn it off is an account that is monitored from the payer instead."
  type        = bool
  default     = true
}

variable "anomaly_monitor_dimension" {
  description = "Dimension a DIMENSIONAL monitor watches. SERVICE is the only value Cost Explorer accepts today and it is what both estates use."
  type        = string
  default     = "SERVICE"

  validation {
    condition     = contains(["SERVICE", "LINKED_ACCOUNT"], var.anomaly_monitor_dimension)
    error_message = "anomaly_monitor_dimension must be SERVICE or LINKED_ACCOUNT."
  }
}

variable "anomaly_threshold" {
  description = "Dollar amount of total absolute impact at or above which an anomaly is reported. It is rendered into the subscription's threshold_expression as a plain decimal string, so 10 becomes \"10\"."
  type        = number
  default     = 10

  validation {
    condition     = var.anomaly_threshold > 0
    error_message = "anomaly_threshold must be greater than zero."
  }
}

variable "anomaly_frequency" {
  description = "How often the subscription sends. DAILY is a digest of the day's anomalies and is the only frequency an EMAIL subscriber may use; IMMEDIATE requires an SNS subscriber."
  type        = string
  default     = "DAILY"

  validation {
    condition     = contains(["DAILY", "IMMEDIATE", "WEEKLY"], var.anomaly_frequency)
    error_message = "anomaly_frequency must be DAILY, IMMEDIATE or WEEKLY."
  }
}

variable "anomaly_sns_topic_arns" {
  description = "SNS topics that receive anomaly notifications, in addition to notification_emails. Cost Explorer requires the topic to allow publishing from costalerts.amazonaws.com, which the consumer sets up. IMMEDIATE frequency needs at least one of these."
  type        = list(string)
  default     = []
}

variable "budgets" {
  description = <<-EOT
    Cost budgets to create, keyed by the suffix appended to name, so the key "monthly-warn" makes
    a budget called "<name>-monthly-warn". Each entry needs limit_amount, a decimal string exactly
    as it is stored (AWS Budgets keeps the limit as a string, so "30" and "30.0" are different
    stored values); everything else has a default. thresholds lists the notification blocks in the
    order they are written. The first two budgets in an account are free.
  EOT

  type = map(object({
    limit_amount = string
    limit_unit   = optional(string, "USD")
    time_unit    = optional(string, "MONTHLY")
    budget_type  = optional(string, "COST")
    thresholds = optional(list(object({
      threshold           = number
      comparison_operator = optional(string, "GREATER_THAN")
      threshold_type      = optional(string, "PERCENTAGE")
      notification_type   = optional(string, "ACTUAL")
    })), [{ threshold = 100 }])
  }))

  default = {}

  validation {
    condition     = alltrue([for suffix in keys(var.budgets) : can(regex("^[a-zA-Z0-9._-]{1,80}$", suffix))])
    error_message = "Every budget key must be 1 to 80 characters of letters, digits, period, underscore or hyphen: it becomes part of the budget name."
  }

  validation {
    condition     = alltrue([for budget in values(var.budgets) : can(tonumber(budget.limit_amount)) && tonumber(budget.limit_amount) > 0])
    error_message = "Every budget's limit_amount must be a positive decimal string, for example \"30\". It is passed to AWS verbatim."
  }

  validation {
    condition     = alltrue([for budget in values(var.budgets) : contains(["MONTHLY", "DAILY", "QUARTERLY", "ANNUALLY"], budget.time_unit)])
    error_message = "Every budget's time_unit must be MONTHLY, DAILY, QUARTERLY or ANNUALLY."
  }

  validation {
    condition     = alltrue([for budget in values(var.budgets) : contains(["COST", "USAGE", "RI_UTILIZATION", "RI_COVERAGE", "SAVINGS_PLANS_UTILIZATION", "SAVINGS_PLANS_COVERAGE"], budget.budget_type)])
    error_message = "Every budget's budget_type must be one of COST, USAGE, RI_UTILIZATION, RI_COVERAGE, SAVINGS_PLANS_UTILIZATION or SAVINGS_PLANS_COVERAGE."
  }

  validation {
    condition = alltrue(flatten([
      for budget in values(var.budgets) : [
        for notification in budget.thresholds : contains(["GREATER_THAN", "LESS_THAN", "EQUAL_TO"], notification.comparison_operator)
      ]
    ]))
    error_message = "Every threshold's comparison_operator must be GREATER_THAN, LESS_THAN or EQUAL_TO."
  }

  validation {
    condition = alltrue(flatten([
      for budget in values(var.budgets) : [
        for notification in budget.thresholds : contains(["PERCENTAGE", "ABSOLUTE_VALUE"], notification.threshold_type)
      ]
    ]))
    error_message = "Every threshold's threshold_type must be PERCENTAGE or ABSOLUTE_VALUE."
  }

  validation {
    condition = alltrue(flatten([
      for budget in values(var.budgets) : [
        for notification in budget.thresholds : contains(["ACTUAL", "FORECASTED"], notification.notification_type)
      ]
    ]))
    error_message = "Every threshold's notification_type must be ACTUAL or FORECASTED."
  }

  validation {
    condition     = alltrue([for budget in values(var.budgets) : length(budget.thresholds) > 0])
    error_message = "Every budget must define at least one threshold, otherwise it never notifies anyone."
  }
}

variable "budget_sns_topic_arns" {
  description = "SNS topics added as a subscriber to every budget notification, in addition to notification_emails. The topic policy must allow budgets.amazonaws.com to publish."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to add to the resource group on top of the provider default_tags. An empty map is passed as null so it plans identically to a group that never set tags. Cost Explorer anomaly monitors, subscriptions and budgets do not take tags."
  type        = map(string)
  default     = {}
}
