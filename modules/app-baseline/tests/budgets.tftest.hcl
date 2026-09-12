variables {
  name = "example-staging"

  notification_emails = ["tyler@webbpulse.com", "tylert2610@gmail.com"]

  resource_group_tag_filters = {
    Project = ["example"]
  }

  budgets = {
    "monthly-warn"     = { limit_amount = "10" }
    "monthly-critical" = { limit_amount = "25" }
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

run "a_budget_is_named_name_prefix_then_the_map_key" {
  command = plan

  assert {
    condition     = length(aws_budgets_budget.this) == 2
    error_message = "One budget must be created per entry in the budgets map, because both estates rely on a warn budget and a critical budget standing side by side."
  }

  assert {
    condition     = aws_budgets_budget.this["monthly-warn"].name == "example-staging-monthly-warn"
    error_message = "A budget's stored name must be <name>-<map key>. The key is the only part a consumer controls, and budget_names publishes the joined string that AWS actually stores."
  }

  assert {
    condition     = aws_budgets_budget.this["monthly-critical"].name == "example-staging-monthly-critical"
    error_message = "The second budget must take the same <name>-<map key> shape, so that renaming the environment prefix moves every budget together rather than leaving orphans behind in the account."
  }
}

run "the_limit_amount_string_is_passed_to_aws_verbatim" {
  command = plan

  assert {
    condition     = aws_budgets_budget.this["monthly-warn"].limit_amount == "10"
    error_message = "limit_amount must reach AWS exactly as the consumer wrote it. AWS Budgets stores the limit as a string, so quietly reformatting \"10\" into \"10.0\" would show as a permanent diff on every plan."
  }

  assert {
    condition     = aws_budgets_budget.this["monthly-critical"].limit_amount == "25"
    error_message = "The critical budget's limit must also pass through untouched: the two limits are what separates a warning from a page, and a mangled string changes the dollar figure people are alerted on."
  }
}

run "budget_defaults_are_a_monthly_usd_cost_budget" {
  command = plan

  assert {
    condition     = alltrue([for budget in aws_budgets_budget.this : budget.limit_unit == "USD"])
    error_message = "limit_unit must default to USD. A COST budget denominated in anything else is either rejected or silently measures the wrong quantity, and neither estate ever passes the argument."
  }

  assert {
    condition     = alltrue([for budget in aws_budgets_budget.this : budget.time_unit == "MONTHLY"])
    error_message = "time_unit must default to MONTHLY. Both estates budget per calendar month, and a DAILY default would fire the same alert thirty times before anybody looked at it."
  }

  assert {
    condition     = alltrue([for budget in aws_budgets_budget.this : budget.budget_type == "COST"])
    error_message = "budget_type must default to COST. USAGE and the reservation budget types measure quantities, not dollars, so a wrong default would make limit_amount mean something entirely different."
  }
}

run "the_default_threshold_is_one_actual_alert_at_one_hundred_percent" {
  command = plan

  assert {
    condition     = length(aws_budgets_budget.this["monthly-warn"].notification) == 1
    error_message = "A budget written with no thresholds must still produce exactly one notification block. A budget that notifies nobody looks configured in the console and silently never alerts."
  }

  assert {
    condition     = one(aws_budgets_budget.this["monthly-warn"].notification).threshold == 100
    error_message = "The default threshold must be 100, meaning the full limit. Both estates rely on the default, so a change here moves every alert in both accounts without any consumer edit."
  }

  assert {
    condition     = one(aws_budgets_budget.this["monthly-warn"].notification).comparison_operator == "GREATER_THAN"
    error_message = "The default comparison_operator must be GREATER_THAN. LESS_THAN or EQUAL_TO on a cost budget would only alert in situations that never come up, so the budget would never fire."
  }

  assert {
    condition     = one(aws_budgets_budget.this["monthly-warn"].notification).threshold_type == "PERCENTAGE"
    error_message = "The default threshold_type must be PERCENTAGE, which makes a threshold of 100 mean the whole limit. Read as ABSOLUTE_VALUE it would mean one hundred dollars regardless of the limit."
  }

  assert {
    condition     = one(aws_budgets_budget.this["monthly-warn"].notification).notification_type == "ACTUAL"
    error_message = "The default notification_type must be ACTUAL, so the alert reflects money already spent. A FORECASTED default would page on a projection that routinely walks back down on its own."
  }
}

run "every_threshold_is_addressed_to_every_notification_email" {
  command = plan

  assert {
    condition = alltrue([
      for budget in aws_budgets_budget.this : alltrue([
        for notification in budget.notification :
        toset(notification.subscriber_email_addresses) == toset(["tyler@webbpulse.com", "tylert2610@gmail.com"])
      ])
    ])
    error_message = "Every notification block on every budget must carry the whole notification_emails list. A threshold that reaches only some of the addresses is invisible until it is the one that breaches and the wrong person is on holiday."
  }

  assert {
    condition = alltrue([
      for budget in aws_budgets_budget.this : alltrue([
        for notification in budget.notification : length(notification.subscriber_sns_topic_arns) == 0
      ])
    ])
    error_message = "With budget_sns_topic_arns unset, no notification may name an SNS topic. An accidental topic ARN on a budget fails the apply because the topic policy has not been written to allow budgets.amazonaws.com."
  }
}

run "each_threshold_entry_becomes_its_own_notification_block" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = {
        limit_amount = "500"

        thresholds = [
          { threshold = 80 },
          { threshold = 100, notification_type = "FORECASTED" },
        ]
      }
    }
  }

  assert {
    condition     = length(aws_budgets_budget.this["monthly-warn"].notification) == 2
    error_message = "Each entry in thresholds must become its own notification block, so one budget can warn early on actual spend and again on a forecast breach."
  }

  assert {
    condition = setunion([
      for notification in aws_budgets_budget.this["monthly-warn"].notification : notification.threshold
    ]) == toset([80, 100])
    error_message = "Both thresholds the consumer listed must survive. Collapsing two entries into one would silently drop either the early warning or the breach alert, and the budget would still look correct in the console."
  }

  assert {
    condition = one([
      for notification in aws_budgets_budget.this["monthly-warn"].notification :
      notification.notification_type if notification.threshold == 80
    ]) == "ACTUAL"
    error_message = "A threshold that does not set notification_type must still default to ACTUAL even when a sibling threshold in the same budget overrides it, because the defaults are per entry and not per budget."
  }

  assert {
    condition = one([
      for notification in aws_budgets_budget.this["monthly-warn"].notification :
      notification.notification_type if notification.threshold == 100
    ]) == "FORECASTED"
    error_message = "A threshold that sets notification_type to FORECASTED must keep it. Forecast alerts are the whole reason a budget carries a second threshold at the same percentage."
  }
}

run "sns_topics_are_added_as_a_subscriber_to_every_notification" {
  command = plan

  variables {
    budget_sns_topic_arns = ["arn:aws:sns:us-west-2:123456789012:example-staging-budget-alerts"]
  }

  assert {
    condition = alltrue([
      for budget in aws_budgets_budget.this : alltrue([
        for notification in budget.notification :
        tolist(notification.subscriber_sns_topic_arns) == tolist(["arn:aws:sns:us-west-2:123456789012:example-staging-budget-alerts"])
      ])
    ])
    error_message = "budget_sns_topic_arns must reach every notification block of every budget. A topic wired to only some thresholds is the kind of gap that is invisible until the one unwired threshold is the one that breaches."
  }

  assert {
    condition = alltrue([
      for budget in aws_budgets_budget.this : alltrue([
        for notification in budget.notification : length(notification.subscriber_email_addresses) == 2
      ])
    ])
    error_message = "Adding an SNS topic must not displace the email subscribers. The topic is documented as being in addition to notification_emails, not a replacement for them."
  }
}

run "an_empty_budgets_map_creates_no_budgets_and_empty_output_maps" {
  command = plan

  variables {
    budgets = {}
  }

  assert {
    condition     = length(aws_budgets_budget.this) == 0
    error_message = "An empty budgets map must create nothing. The first two budgets in an account are free but further ones are billed, so the module must never invent a budget the consumer did not ask for."
  }

  assert {
    condition     = length(output.budget_names) == 0
    error_message = "budget_names must be an empty map rather than null when there are no budgets, so a consumer can index or iterate it without a conditional."
  }

  assert {
    condition     = length(output.budget_arns) == 0
    error_message = "budget_arns must be an empty map rather than null when there are no budgets, for the same reason: a consumer feeding it into a policy must not have to guard against null."
  }
}

run "a_budget_key_outside_the_allowed_character_set_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly warn" = { limit_amount = "10" }
    }
  }

  expect_failures = [var.budgets]
}

run "a_budget_limit_that_is_not_a_positive_number_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = { limit_amount = "free" }
    }
  }

  expect_failures = [var.budgets]
}

run "a_zero_budget_limit_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = { limit_amount = "0" }
    }
  }

  expect_failures = [var.budgets]
}

run "an_unknown_time_unit_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = { limit_amount = "10", time_unit = "WEEKLY" }
    }
  }

  expect_failures = [var.budgets]
}

run "an_unknown_budget_type_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = { limit_amount = "10", budget_type = "SPEND" }
    }
  }

  expect_failures = [var.budgets]
}

run "an_unknown_comparison_operator_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = {
        limit_amount = "10"
        thresholds   = [{ threshold = 100, comparison_operator = "GREATER_THAN_OR_EQUAL" }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "an_unknown_threshold_type_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = {
        limit_amount = "10"
        thresholds   = [{ threshold = 100, threshold_type = "DOLLARS" }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "an_unknown_notification_type_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = {
        limit_amount = "10"
        thresholds   = [{ threshold = 100, notification_type = "PREDICTED" }]
      }
    }
  }

  expect_failures = [var.budgets]
}

run "a_budget_with_an_empty_threshold_list_is_rejected" {
  command = plan

  variables {
    budgets = {
      "monthly-warn" = {
        limit_amount = "10"
        thresholds   = []
      }
    }
  }

  expect_failures = [var.budgets]
}
