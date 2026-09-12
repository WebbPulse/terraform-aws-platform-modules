variables {
  name = "example-staging"

  notification_emails = ["tyler@webbpulse.com", "tylert2610@gmail.com"]

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

run "anomaly_detection_is_on_by_default_as_one_monitor_and_one_subscription" {
  command = plan

  assert {
    condition     = length(aws_ce_anomaly_monitor.this) == 1
    error_message = "Cost anomaly detection must default to on. It costs nothing and is the only thing in this module that catches a spend spike between billing cycles, so a consumer that passes nothing still gets it."
  }

  assert {
    condition     = length(aws_ce_anomaly_subscription.this) == 1
    error_message = "A monitor without a subscription detects anomalies and tells nobody. The pair must be created together so that turning detection on always means somebody is notified."
  }

  assert {
    condition     = one(aws_ce_anomaly_monitor.this[*].name) == "example-staging"
    error_message = "The monitor must be named with var.name verbatim, with no suffix, because that is the name both estates already have in their accounts and a rename destroys and recreates the monitor along with its learned baseline."
  }

  assert {
    condition     = one(aws_ce_anomaly_subscription.this[*].name) == "example-staging"
    error_message = "The subscription must also take var.name verbatim. Sharing the name with the monitor is what makes the pair legible in the Cost Explorer console."
  }
}

run "the_monitor_is_a_dimensional_service_monitor_by_default" {
  command = plan

  assert {
    condition     = one(aws_ce_anomaly_monitor.this[*].monitor_type) == "DIMENSIONAL"
    error_message = "The monitor must be DIMENSIONAL. A CUSTOM monitor requires a cost-category expression that neither estate defines, so the monitor type is not something a consumer may accidentally flip."
  }

  assert {
    condition     = one(aws_ce_anomaly_monitor.this[*].monitor_dimension) == "SERVICE"
    error_message = "The monitor dimension must default to SERVICE, which is what makes an anomaly attributable to the AWS service that caused it. LINKED_ACCOUNT only makes sense from a payer account watching its members."
  }
}

run "the_subscription_wires_the_monitor_it_created" {
  command = plan

  override_resource {
    target          = aws_ce_anomaly_monitor.this
    override_during = plan
    values = {
      arn = "arn:aws:ce::123456789012:anomalymonitor/example-staging"
    }
  }

  assert {
    condition     = one(aws_ce_anomaly_subscription.this[*].monitor_arn_list) == tolist(["arn:aws:ce::123456789012:anomalymonitor/example-staging"])
    error_message = "The subscription must watch exactly the one monitor this module creates, and nothing else. An empty list makes the subscription inert, and an extra ARN would send another estate's anomalies to this audience."
  }

  assert {
    condition     = one(aws_ce_anomaly_subscription.this[*].frequency) == "DAILY"
    error_message = "The frequency must default to DAILY. DAILY is the only frequency Cost Explorer accepts for an EMAIL subscriber, and notification_emails is the default audience, so any other default breaks the common case at apply time."
  }
}

run "every_notification_email_becomes_its_own_email_subscriber" {
  command = plan

  assert {
    condition     = length(one(aws_ce_anomaly_subscription.this[*].subscriber)) == 2
    error_message = "Each address in notification_emails must become its own subscriber block, so both people on the rota receive the anomaly digest rather than only the first."
  }

  assert {
    condition = alltrue([
      for subscriber in one(aws_ce_anomaly_subscription.this[*].subscriber) : subscriber.type == "EMAIL"
    ])
    error_message = "With no SNS topics passed, every subscriber must be of type EMAIL. A subscriber typed SNS whose address is an email address is rejected by Cost Explorer at apply time."
  }

  assert {
    condition = setunion([
      for subscriber in one(aws_ce_anomaly_subscription.this[*].subscriber) : subscriber.address
    ]) == toset(["tyler@webbpulse.com", "tylert2610@gmail.com"])
    error_message = "Every address given must appear as a subscriber address and no others may be invented. A dropped address means one of the two people watching spend silently stops receiving the digest."
  }
}

run "sns_subscribers_are_added_alongside_the_email_subscribers" {
  command = plan

  variables {
    anomaly_sns_topic_arns = ["arn:aws:sns:us-west-2:123456789012:example-staging-cost-alerts"]
  }

  assert {
    condition     = length(one(aws_ce_anomaly_subscription.this[*].subscriber)) == 3
    error_message = "SNS topics are documented as being in addition to notification_emails, so two addresses plus one topic must produce three subscriber blocks rather than replacing the emails."
  }

  assert {
    condition = length([
      for subscriber in one(aws_ce_anomaly_subscription.this[*].subscriber) : subscriber if subscriber.type == "EMAIL"
    ]) == 2
    error_message = "Adding a topic must leave both email subscribers in place. If an SNS topic displaced them, the people who read the digest would stop receiving it the moment a paging route was added."
  }

  assert {
    condition = one([
      for subscriber in one(aws_ce_anomaly_subscription.this[*].subscriber) : subscriber.address if subscriber.type == "SNS"
    ]) == "arn:aws:sns:us-west-2:123456789012:example-staging-cost-alerts"
    error_message = "An SNS subscriber's address must be the topic ARN exactly as passed, because Cost Explorer resolves the publish target from that string and the consumer is the one who authorised costalerts.amazonaws.com on it."
  }
}

run "the_threshold_is_rendered_as_an_absolute_impact_dimension" {
  command = plan

  assert {
    condition     = one(one(one(aws_ce_anomaly_subscription.this[*].threshold_expression)).dimension).key == "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
    error_message = "The threshold must be expressed on ANOMALY_TOTAL_IMPACT_ABSOLUTE, which is dollars. ANOMALY_TOTAL_IMPACT_PERCENTAGE would read the same number as a percentage and flood a small account with alerts."
  }

  assert {
    condition     = tolist(one(one(one(aws_ce_anomaly_subscription.this[*].threshold_expression)).dimension).match_options) == tolist(["GREATER_THAN_OR_EQUAL"])
    error_message = "The match option must be GREATER_THAN_OR_EQUAL, so an anomaly exactly at the threshold is reported. Anything else changes which anomalies reach the inbox without changing the documented number."
  }

  assert {
    condition     = tolist(one(one(one(aws_ce_anomaly_subscription.this[*].threshold_expression)).dimension).values) == tolist(["10"])
    error_message = "The default threshold of 10 must render as the string \"10\". The value is formatted with %g precisely so that a whole-dollar threshold does not store as \"10.0\", which is the string both estates already hold."
  }
}

run "a_fractional_threshold_keeps_its_cents_when_it_is_formatted" {
  command = plan

  variables {
    anomaly_threshold = 12.5
  }

  assert {
    condition     = local.anomaly_threshold_value == "12.5"
    error_message = "A threshold that genuinely has cents must survive formatting. %g must trim a trailing zero without also rounding away a real fractional part, or the alerting threshold silently moves."
  }

  assert {
    condition     = tolist(one(one(one(aws_ce_anomaly_subscription.this[*].threshold_expression)).dimension).values) == tolist(["12.5"])
    error_message = "The formatted string is what reaches the API, so the subscription must carry \"12.5\" rather than a rounded or exponent-notation rendering of the same number."
  }
}

run "the_monitor_dimension_can_be_switched_to_linked_account" {
  command = plan

  variables {
    anomaly_monitor_dimension = "LINKED_ACCOUNT"
  }

  assert {
    condition     = one(aws_ce_anomaly_monitor.this[*].monitor_dimension) == "LINKED_ACCOUNT"
    error_message = "A payer account must be able to watch per member account instead of per service, so the dimension has to be a real passthrough rather than a hardcoded SERVICE."
  }
}

run "an_immediate_subscription_can_be_pointed_at_an_sns_topic" {
  command = plan

  variables {
    anomaly_frequency      = "IMMEDIATE"
    notification_emails    = []
    anomaly_sns_topic_arns = ["arn:aws:sns:us-west-2:123456789012:example-staging-cost-alerts"]
  }

  assert {
    condition     = one(aws_ce_anomaly_subscription.this[*].frequency) == "IMMEDIATE"
    error_message = "IMMEDIATE must be available for the paging case, where an anomaly should reach an on-call route rather than wait for the next daily digest."
  }

  assert {
    condition     = length(one(aws_ce_anomaly_subscription.this[*].subscriber)) == 1
    error_message = "With no email addresses, only the SNS topic may be a subscriber. IMMEDIATE requires an SNS subscriber, so the SNS path must stand on its own without any email subscriber present."
  }

  assert {
    condition     = one([for subscriber in one(aws_ce_anomaly_subscription.this[*].subscriber) : subscriber.type]) == "SNS"
    error_message = "The lone subscriber must be typed SNS, because Cost Explorer rejects an IMMEDIATE subscription whose subscribers are email addresses."
  }
}

run "turning_anomaly_detection_off_removes_both_resources_and_nulls_both_outputs" {
  command = plan

  variables {
    anomaly_detection_enabled = false
  }

  assert {
    condition     = length(aws_ce_anomaly_monitor.this) == 0
    error_message = "An account monitored from the payer must be able to opt out entirely, so the monitor has to disappear rather than merely stop notifying."
  }

  assert {
    condition     = length(aws_ce_anomaly_subscription.this) == 0
    error_message = "The subscription must go with the monitor. A subscription left behind references a monitor ARN that no longer exists and fails the apply."
  }

  assert {
    condition     = output.anomaly_monitor_arn == null
    error_message = "anomaly_monitor_arn must be null rather than an error when detection is off, because it is documented as the handle a consumer passes to a second subscription and must be safely testable for null."
  }

  assert {
    condition     = output.anomaly_subscription_arn == null
    error_message = "anomaly_subscription_arn must be null when detection is off, so a consumer can reference it unconditionally in an output or a locals block."
  }
}

run "an_unknown_monitor_dimension_is_rejected" {
  command = plan

  variables {
    anomaly_monitor_dimension = "REGION"
  }

  expect_failures = [var.anomaly_monitor_dimension]
}

run "an_unknown_frequency_is_rejected" {
  command = plan

  variables {
    anomaly_frequency = "HOURLY"
  }

  expect_failures = [var.anomaly_frequency]
}

run "a_zero_threshold_is_rejected" {
  command = plan

  variables {
    anomaly_threshold = 0
  }

  expect_failures = [var.anomaly_threshold]
}

run "a_negative_threshold_is_rejected" {
  command = plan

  variables {
    anomaly_threshold = -5
  }

  expect_failures = [var.anomaly_threshold]
}
