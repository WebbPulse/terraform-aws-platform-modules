variables {
  name_prefix = "example-staging"

  error_log_groups = {
    content  = "/aws/lambda/example-staging-content"
    resume   = "/aws/lambda/example-staging-resume"
    identity = "/aws/lambda/example-staging-identity"
    public   = "/aws/lambda/example-staging-public"
  }

  alarms = {
    application_errors     = true
    rate_limit_failed_open = true
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

run "off_by_default_even_with_error_log_groups_set" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.rate_limit_failed_open) == 0
    error_message = "rate_limit_fail_open_alarm defaults to false, so a consumer passing only error_log_groups must get no fail open metric filters."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rate_limit_failed_open) == 0
    error_message = "rate_limit_fail_open_alarm defaults to false, so no fail open alarm may be created."
  }
}

run "one_filter_per_log_group_and_exactly_one_alarm" {
  command = plan

  variables {
    rate_limit_fail_open_alarm = true
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.rate_limit_failed_open) == 4
    error_message = "The log groups must default to error_log_groups, which holds four entries, so there must be one filter each."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rate_limit_failed_open) == 1
    error_message = "Four log groups must still produce exactly one alarm: that is what keeps the alarm count flat as the estate grows."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.rate_limit_failed_open[*].alarm_name) == "example-staging-rate-limit-failed-open"
    error_message = "The alarm name must be <name_prefix>-rate-limit-failed-open and must not embed a function or log group name."
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.rate_limit_failed_open["content"].name == "example-staging-content-rate-limit-failed-open"
    error_message = "A filter must be named <name_prefix>-<key>-rate-limit-failed-open, because the key is what tells a responder which log group fired."
  }
}

run "every_filter_publishes_one_dimensionless_metric_with_a_zero_default" {
  command = plan

  variables {
    rate_limit_fail_open_alarm = true
  }

  assert {
    condition = alltrue([
      for f in values(aws_cloudwatch_log_metric_filter.rate_limit_failed_open) :
      one(f.metric_transformation).name == "example-staging-rate-limit-failed-open"
    ])
    error_message = "Every filter must publish to the same metric name, which is what makes one alarm the sum across all of them."
  }

  assert {
    condition = alltrue([
      for f in values(aws_cloudwatch_log_metric_filter.rate_limit_failed_open) :
      length(coalesce(one(f.metric_transformation).dimensions, {})) == 0
    ])
    error_message = "The metric must carry no dimensions: a dimension would split it into one series per log group and put the alarm on metric math."
  }

  assert {
    condition = alltrue([
      for f in values(aws_cloudwatch_log_metric_filter.rate_limit_failed_open) :
      one(f.metric_transformation).default_value == "0"
    ])
    error_message = "default_value must be 0 so the metric reports a real zero in quiet periods rather than a gap."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.rate_limit_failed_open[*].metric_name) != one(aws_cloudwatch_metric_alarm.errors[*].metric_name)
    error_message = "The fail open metric must not be the application errors metric: the two mean different things and want separate thresholds."
  }
}

run "the_alarm_is_a_plain_sum_metric_alarm" {
  command = plan

  variables {
    rate_limit_fail_open_alarm = true
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.rate_limit_failed_open[*].statistic) == "Sum"
    error_message = "The alarm must take the Sum: on a dimensionless metric that is already the total across every filter."
  }

  assert {
    condition     = length(one(aws_cloudwatch_metric_alarm.rate_limit_failed_open[*].metric_query)) == 0
    error_message = "The alarm must be a plain metric alarm, not metric math, so the number of log groups it covers has no ceiling."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.rate_limit_failed_open[*].treat_missing_data) == "notBreaching"
    error_message = "No fail open records at all is the healthy state, so missing data must be notBreaching."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.rate_limit_failed_open[*].evaluation_periods) == 1
    error_message = "One evaluation period of five minutes: a single fail open is worth an alarm."
  }
}

run "the_log_group_override_replaces_rather_than_merges" {
  command = plan

  variables {
    rate_limit_fail_open_alarm = true

    rate_limit_fail_open_log_groups = {
      identity = "/aws/lambda/example-staging-identity"
    }
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.rate_limit_failed_open) == 1
    error_message = "An explicit rate_limit_fail_open_log_groups must replace error_log_groups, not merge with it."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rate_limit_failed_open) == 1
    error_message = "One log group must still produce exactly one alarm."
  }
}

run "the_switch_alone_creates_nothing" {
  command = plan

  variables {
    rate_limit_fail_open_alarm      = true
    error_log_groups                = {}
    rate_limit_fail_open_log_groups = {}
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rate_limit_failed_open) == 0
    error_message = "With no log groups to watch there must be no alarm: an alarm with no metric filter feeding it can never leave INSUFFICIENT_DATA."
  }
}
