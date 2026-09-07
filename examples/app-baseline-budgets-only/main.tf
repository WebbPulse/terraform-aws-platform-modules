# An account that already has a resource group and is monitored for anomalies from the payer
# account still wants its own budgets. Turning the other two parts off makes the module create
# nothing but the budgets, and a forecast alert gives warning before the money is spent rather
# than after.

variable "sns_topic_arn" {
  description = "Topic that pages on a budget breach, in addition to the email addresses. Its policy must allow budgets.amazonaws.com to publish."
  type        = string
  default     = null
}

provider "aws" {
  region = "us-west-2"
}

module "app_baseline" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline"
  version = "~> 1.6"

  name                = "example-production"
  notification_emails = ["finance@example.com", "oncall@example.com"]

  resource_group_enabled    = false
  anomaly_detection_enabled = false

  budget_sns_topic_arns = var.sns_topic_arn == null ? [] : [var.sns_topic_arn]

  budgets = {
    "monthly-warn" = {
      limit_amount = "500"

      thresholds = [
        # 80 percent of the month's budget already spent.
        { threshold = 80 },
        # On track to finish the month over budget, which arrives days earlier than the actual.
        { threshold = 100, notification_type = "FORECASTED" },
      ]
    }

    "monthly-critical" = {
      limit_amount = "1000"
      thresholds   = [{ threshold = 100 }]
    }
  }
}

output "budget_arns" {
  description = "ARNs of the budgets, for a policy or a notification rule that names one."
  value       = module.app_baseline.budget_arns
}
