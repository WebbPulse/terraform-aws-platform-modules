# The shape both WebbPulse application estates use: one resource group that collects everything
# tagged with the project, cost anomaly detection on the SERVICE dimension, and the two free
# budgets. Every alert goes to the same two addresses.

variable "environment" {
  description = "production or staging"
  type        = string
  default     = "staging"
}

locals {
  project = "example"
  prefix  = "${local.project}-${var.environment}"

  common_tags = {
    Project     = local.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = local.common_tags
  }
}

module "app_baseline" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline"
  version = "~> 1.6"

  name                = local.prefix
  notification_emails = ["alerts@example.com"]

  # The group matches the project tag, not the prefix: local.prefix carries the environment, and
  # the resources are tagged Project = example in both environments.
  resource_group_description = "All Example managed resources"
  resource_group_tag_filters = {
    Project = [local.project]
  }

  # Production spends more than staging, so the same code gives each environment its own limits.
  budgets = {
    "monthly-warn"     = { limit_amount = var.environment == "production" ? "30" : "10" }
    "monthly-critical" = { limit_amount = var.environment == "production" ? "60" : "25" }
  }
}

output "resource_group_arn" {
  description = "Console link target for the project's resource group."
  value       = module.app_baseline.resource_group_arn
}

output "budget_names" {
  description = "The budget names AWS stores."
  value       = module.app_baseline.budget_names
}
