variables {
  name = "example-staging"

  notification_emails = ["tyler@webbpulse.com"]

  resource_group_tag_filters = {
    Project = ["example"]
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "a_name_with_a_space_is_rejected" {
  command = plan

  variables {
    name = "example staging"
  }

  expect_failures = [var.name]
}

run "an_empty_name_is_rejected" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}

run "a_malformed_notification_email_is_rejected" {
  command = plan

  variables {
    notification_emails = ["tyler@webbpulse.com", "not-an-address"]
  }

  expect_failures = [var.notification_emails]
}

run "a_notification_email_containing_whitespace_is_rejected" {
  command = plan

  variables {
    notification_emails = ["tyler webb@webbpulse.com"]
  }

  expect_failures = [var.notification_emails]
}

run "a_repeated_notification_email_is_rejected" {
  command = plan

  variables {
    notification_emails = ["tyler@webbpulse.com", "tyler@webbpulse.com"]
  }

  expect_failures = [var.notification_emails]
}

run "no_notification_emails_at_all_still_plans" {
  command = plan

  variables {
    notification_emails = []

    anomaly_sns_topic_arns = ["arn:aws:sns:us-west-2:123456789012:example-staging-cost-alerts"]

    budgets = {
      "monthly-warn" = { limit_amount = "10" }
    }
  }

  assert {
    condition     = length(one(aws_ce_anomaly_subscription.this[*].subscriber)) == 1
    error_message = "An estate that routes everything through SNS must be able to pass no email addresses at all, leaving the topic as the only subscriber."
  }

  assert {
    condition     = length(one(aws_budgets_budget.this["monthly-warn"].notification).subscriber_email_addresses) == 0
    error_message = "With no addresses given, a budget notification must carry an empty subscriber list rather than inventing one. An address the consumer never wrote would send cost alerts to the wrong inbox."
  }
}

run "the_whole_module_can_be_reduced_to_budgets_alone" {
  command = plan

  variables {
    resource_group_enabled     = false
    anomaly_detection_enabled  = false
    resource_group_tag_filters = {}

    notification_emails = ["finance@example.com", "oncall@example.com"]

    budgets = {
      "monthly-warn"     = { limit_amount = "500" }
      "monthly-critical" = { limit_amount = "1000" }
    }
  }

  assert {
    condition     = length(aws_resourcegroups_group.this) == 0 && length(aws_ce_anomaly_monitor.this) == 0 && length(aws_ce_anomaly_subscription.this) == 0
    error_message = "The budgets-only shape documented in the examples must plan to budgets and nothing else, so an account already covered from the payer can adopt the module for its budgets alone."
  }

  assert {
    condition     = length(aws_budgets_budget.this) == 2
    error_message = "Switching off the group and the anomaly monitor must leave the budgets untouched. The three features are independent, and coupling them would make the budgets-only example impossible."
  }

  assert {
    condition     = output.budget_names == { "monthly-warn" = "example-staging-monthly-warn", "monthly-critical" = "example-staging-monthly-critical" }
    error_message = "budget_names must map each key to the full stored name even with every other feature off, because that map is how a consumer finds a budget in the console or names it in a notification rule."
  }
}
