variables {
  name               = "example-staging"
  availability_zones = ["us-west-2a", "us-west-2b"]
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

run "flow_logs_are_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_flow_log.this) == 0 && length(aws_cloudwatch_log_group.flow_logs) == 0 && length(aws_iam_role.flow_logs) == 0
    error_message = "Flow logs must be off by default, including the log group and role. A VPC carrying only short lived task traffic would pay CloudWatch Logs ingestion for records nobody reads."
  }
}

run "enabling_flow_logs_creates_the_log_group_role_and_flow_log" {
  command = plan

  variables {
    enable_flow_logs = true
  }

  assert {
    condition     = length(aws_flow_log.this) == 1 && length(aws_cloudwatch_log_group.flow_logs) == 1 && length(aws_iam_role.flow_logs) == 1
    error_message = "Turning flow logs on must create the whole set. A flow log without its own role cannot write, and it reports that failure only in the flow log's status field where nobody looks."
  }

  assert {
    condition     = aws_flow_log.this[0].traffic_type == "REJECT"
    error_message = "The traffic type must default to REJECT. Rejected traffic is the small set worth reading when debugging a task that cannot reach something, while ALL on a busy VPC is the expensive default that gets flow logs turned back off."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 7
    error_message = "Retention must default to 7 days, matching the log retention floor the rest of this repository uses. A group with no retention keeps records forever and bills storage for them forever."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].name == "/aws/vpc/example-staging/flow-logs"
    error_message = "The log group must be named under the /aws/vpc prefix so it sorts with the other VPC groups rather than at the root of the log group listing."
  }
}

run "the_traffic_type_and_retention_are_selectable" {
  command = plan

  variables {
    enable_flow_logs            = true
    flow_logs_traffic_type      = "ALL"
    flow_logs_retention_in_days = 30
  }

  assert {
    condition     = aws_flow_log.this[0].traffic_type == "ALL"
    error_message = "ALL must be selectable for an investigation that needs the accepted traffic too, since the alternative is managing the flow log outside the module."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 30
    error_message = "Retention must be a passthrough so a longer investigation window can be set without editing the module."
  }
}

run "an_unknown_traffic_type_is_rejected" {
  command = plan

  variables {
    enable_flow_logs       = true
    flow_logs_traffic_type = "DENY"
  }

  expect_failures = [var.flow_logs_traffic_type]
}

run "a_retention_cloudwatch_does_not_accept_is_rejected" {
  command = plan

  variables {
    enable_flow_logs            = true
    flow_logs_retention_in_days = 45
  }

  expect_failures = [var.flow_logs_retention_in_days]
}
