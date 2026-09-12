variables {
  name_prefix = "example-staging"

  error_log_groups = {
    content  = "/aws/lambda/example-staging-content"
    identity = "/aws/lambda/example-staging-identity"
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

run "default_error_pattern_excludes_the_exporter_loggers" {
  command = plan

  assert {
    condition     = local.error_filter_pattern == "{ $.level = \"ERROR\" && ($.logger NOT EXISTS || ($.logger != \"opentelemetry.exporter.otlp.proto.http.trace_exporter\" && $.logger != \"opentelemetry.sdk.trace.export\" && $.logger != \"webbpulse.otel\")) }"
    error_message = "The built pattern must exclude every default logger and must keep matching an ERROR record that carries no logger field, or the change narrows coverage instead of only removing telemetry noise."
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.errors["identity"].pattern == local.error_filter_pattern
    error_message = "Every error metric filter must be created with the built pattern."
  }
}

run "an_explicit_pattern_still_wins" {
  command = plan

  variables {
    error_filter_pattern = "{ $.level = \"CRITICAL\" }"
  }

  assert {
    condition     = local.error_filter_pattern == "{ $.level = \"CRITICAL\" }"
    error_message = "A literal error_filter_pattern must override the built default, because a consumer that has tuned its own match must not have it silently rewritten."
  }
}

run "an_empty_exclusion_list_restores_the_bare_pattern" {
  command = plan

  variables {
    error_excluded_loggers = []
  }

  assert {
    condition     = local.error_filter_pattern == "{ $.level = \"ERROR\" }"
    error_message = "Excluding nothing must produce the plain level match rather than a dangling compound expression."
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.telemetry_errors) == 0
    error_message = "With nothing excluded there is nothing for the telemetry filters to count, so none may be created."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.telemetry_errors) == 0
    error_message = "With no telemetry filters there must be no telemetry alarm."
  }
}

run "telemetry_filters_match_exactly_the_excluded_loggers" {
  command = plan

  assert {
    condition     = local.telemetry_filter_pattern == "{ $.level = \"ERROR\" && ($.logger = \"opentelemetry.exporter.otlp.proto.http.trace_exporter\" || $.logger = \"opentelemetry.sdk.trace.export\" || $.logger = \"webbpulse.otel\") }"
    error_message = "The telemetry pattern must be the complement of the error pattern over the same logger list, so an excluded record is counted somewhere rather than dropped."
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.telemetry_errors) == 2
    error_message = "The telemetry filters must cover the same log groups as the error filters, one each."
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.telemetry_errors["content"].name == "example-staging-content-telemetry-export-errors"
    error_message = "A telemetry filter must be named <name_prefix>-<key>-telemetry-export-errors."
  }
}

run "one_aggregate_telemetry_alarm_never_one_per_function" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.telemetry_errors) == 1
    error_message = "Two log groups must still produce exactly one telemetry alarm: the alarm count must stay flat as the estate grows."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.telemetry_errors[*].alarm_name) == "example-staging-telemetry-export-errors"
    error_message = "The alarm name must be <name_prefix>-telemetry-export-errors and must not embed a function or log group name."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.telemetry_errors[*].threshold) == 20
    error_message = "The telemetry alarm must default to a rate threshold of 20 rather than the application alarm's zero, because a few dropped batches an hour is normal."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.telemetry_errors[*].period) == 3600
    error_message = "The telemetry alarm must default to a one hour period so the threshold reads as an hourly rate."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.telemetry_errors[*].treat_missing_data) == "notBreaching"
    error_message = "A quiet hour means the exporter is healthy, so missing data must not breach."
  }

  assert {
    condition     = one(aws_cloudwatch_metric_alarm.telemetry_errors[*].metric_name) != local.error_metric_name
    error_message = "The telemetry alarm must watch its own metric, otherwise the noise is still summed into the application errors series."
  }
}

run "the_telemetry_alarm_pages_the_same_topic" {
  command = plan

  assert {
    condition     = length(local.alarm_actions) > 0
    error_message = "The module must have at least one alarm action for the telemetry alarm to be visible through."
  }

  assert {
    condition     = length(local.ok_actions) > 0
    error_message = "notify_on_ok defaults to true, so the shared ok_actions both alarms read must be non-empty."
  }
}

run "the_toggle_removes_the_telemetry_resources_only" {
  command = plan

  variables {
    telemetry_alarm_enabled = false
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.telemetry_errors) == 0
    error_message = "telemetry_alarm_enabled = false must create no telemetry metric filters."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.telemetry_errors) == 0
    error_message = "telemetry_alarm_enabled = false must create no telemetry alarm."
  }

  assert {
    condition     = local.error_filter_pattern == "{ $.level = \"ERROR\" && ($.logger NOT EXISTS || ($.logger != \"opentelemetry.exporter.otlp.proto.http.trace_exporter\" && $.logger != \"opentelemetry.sdk.trace.export\" && $.logger != \"webbpulse.otel\")) }"
    error_message = "Turning the telemetry alarm off must not put the noisy loggers back onto the application errors alarm."
  }
}

run "no_error_log_groups_still_creates_nothing" {
  command = plan

  variables {
    error_log_groups = {}
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.telemetry_errors) == 0
    error_message = "With no log groups to watch there must be no telemetry filters."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.telemetry_errors) == 0
    error_message = "With no telemetry filters there must be no telemetry alarm."
  }
}
