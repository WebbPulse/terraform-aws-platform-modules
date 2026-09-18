variables {
  name = "example-staging-run"

  definition = "{\"Comment\":\"example\",\"StartAt\":\"Done\",\"States\":{\"Done\":{\"Type\":\"Succeed\"}}}"
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

override_resource {
  target          = aws_sfn_state_machine.this
  override_during = plan
  values = {
    arn = "arn:aws:states:us-west-2:123456789012:stateMachine:example-staging-run"
  }
}

run "the_role_name_defaults_to_the_machine_name_with_a_role_suffix" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "example-staging-run-role"
    error_message = "With role_name left null the execution role must be named <name>-role; changing that name replaces the role and every policy attached to it, so the derived default has to stay stable."
  }

  assert {
    condition     = aws_iam_role.this.path == "/"
    error_message = "role_path must default to the account root path, which is where an IAM role created without a path lives; a different default would move an adopting consumer's role and force a replacement."
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "No permissions boundary may be set unless a consumer asks for one: a boundary attached by surprise silently narrows every policy later attached to this role."
  }
}

run "the_trust_policy_names_only_the_step_functions_service" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "The trust policy must be exactly one statement; every additional statement is another way into the role."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Service == "states.amazonaws.com"
    error_message = "The trust policy must name states.amazonaws.com and nothing else: it is the principal the state machine itself assumes, and anything wider is a role another service can wear."
  }
}

run "the_logging_grant_is_attached_unconditionally" {
  command = plan

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.logging.policy).Statement[0].Action, "logs:CreateLogDelivery")
    error_message = "The execution role must carry logs:CreateLogDelivery. Step Functions logging goes through vended log delivery, which the service sets up as the role rather than as itself, and without this action the CreateStateMachine call fails outright."
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.logging.policy).Statement[0].Action, "logs:PutResourcePolicy")
    error_message = "logs:PutResourcePolicy is part of the vended delivery setup: the service writes a resource policy on the destination group, and a role without it cannot create a logging state machine."
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.logging.policy).Statement[0].Action, "logs:PutLogEvents")
    error_message = "logs:PutLogEvents must be granted, or the machine is created successfully and then logs nothing, which is the failure mode that looks like the log group simply being empty."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.logging.policy).Statement[0].Resource == "*"
    error_message = "The logging statement's resource must be * because the vended log delivery actions do not take resource-level permissions; that is a property of the CloudWatch Logs IAM surface, not a wildcard chosen for convenience."
  }
}

run "no_work_policy_exists_until_the_caller_gives_statements" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.work) == 0
    error_message = "An empty policy_statements list must create no inline work policy, so a consumer attaching the machine's permissions from outside does not end up with an empty policy resource it has to reason about."
  }

  assert {
    condition     = length(aws_iam_role_policy.xray_write) == 0
    error_message = "With tracing off there is nothing to publish, so the X-Ray grant must be skipped without a separate opt out."
  }

  assert {
    condition     = !output.xray_write_policy_attached
    error_message = "The xray_write_policy_attached output must report false when tracing is off, because a consumer reads it to decide whether its own policy still has to carry the X-Ray actions."
  }
}

run "the_caller_supplied_statements_become_the_work_policy" {
  command = plan

  variables {
    policy_name = "run-work"

    policy_statements = [
      {
        sid       = "RunPlanTask"
        actions   = ["ecs:RunTask"]
        resources = ["arn:aws:ecs:us-west-2:123456789012:task-definition/example-plan:*"]
        condition = {
          ArnEquals = {
            "ecs:cluster" = ["arn:aws:ecs:us-west-2:123456789012:cluster/example-staging"]
          }
        }
      },
      {
        sid       = "StopTask"
        actions   = ["ecs:StopTask", "ecs:DescribeTasks"]
        resources = ["*"]
      },
    ]
  }

  assert {
    condition     = aws_iam_role_policy.work[0].name == "run-work"
    error_message = "policy_name must name the inline work policy, because a consumer adopting a role whose policy already has a name needs the module to land on exactly that name rather than replacing the policy."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.work[0].policy).Statement) == 2
    error_message = "Every caller-supplied statement must reach the policy; dropping one leaves the machine denied at the state that needs it, which surfaces as a runtime task failure rather than an apply error."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.work[0].policy).Statement[0].Action == "ecs:RunTask"
    error_message = "A single-element actions list must render as a bare JSON string, matching how a hand-written policy is usually spelled, so adopting this module leaves an existing policy document byte-identical."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.work[0].policy).Statement[1].Action == ["ecs:StopTask", "ecs:DescribeTasks"]
    error_message = "A multi-element actions list must render as a JSON list and keep the caller's order, because a reordered document is a diff on every plan even though the grant is unchanged."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.work[0].policy).Statement[0].Condition.ArnEquals["ecs:cluster"] == "arn:aws:ecs:us-west-2:123456789012:cluster/example-staging"
    error_message = "A single-value condition must render as a bare string too; this is the condition that keeps an ecs:RunTask grant from reaching every cluster in the account, so it has to survive rendering intact."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.work[0].policy).Statement[0].Effect == "Allow"
    error_message = "effect must default to Allow, which is what a statement listing actions to permit means; a statement defaulting to Deny would invert every grant a consumer writes."
  }
}

run "tracing_on_attaches_the_xray_grant" {
  command = plan

  variables {
    tracing_enabled = true
  }

  assert {
    condition     = aws_sfn_state_machine.this.tracing_configuration[0].enabled
    error_message = "tracing_enabled must reach the state machine, or the executions produce no X-Ray segments at all."
  }

  assert {
    condition     = length(aws_iam_role_policy.xray_write) == 1
    error_message = "A traced state machine without the X-Ray write grant emits nothing: the service tries to publish the segment, the call is denied, and the trace is absent with no error recorded on the execution. That silent failure is why the grant follows the toggle."
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.xray_write[0].policy).Statement[0].Action, "xray:GetSamplingRules")
    error_message = "Step Functions makes its own sampling decision, unlike Lambda, so the role needs GetSamplingRules and GetSamplingTargets on top of the two publish actions; a Lambda-shaped X-Ray policy is not enough here."
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.xray_write[0].policy).Statement[0].Action, "xray:PutTraceSegments")
    error_message = "xray:PutTraceSegments is the action that actually publishes the segment, so its absence means traces never appear however the sampling resolves."
  }

  assert {
    condition     = output.xray_write_policy_attached
    error_message = "The output must report true here, because a consumer branching on it would otherwise duplicate a grant the module already made."
  }
}

run "an_estate_that_grants_xray_itself_can_turn_the_policy_off" {
  command = plan

  variables {
    tracing_enabled          = true
    attach_xray_write_policy = false
  }

  assert {
    condition     = length(aws_iam_role_policy.xray_write) == 0
    error_message = "attach_xray_write_policy false must create no inline policy, so an estate granting the X-Ray actions from its own policy does not end up with a duplicate grant."
  }

  assert {
    condition     = aws_sfn_state_machine.this.tracing_configuration[0].enabled
    error_message = "Turning the grant off must not turn tracing off: they are separate decisions, and an estate opting out of the grant still wants sampling on."
  }
}

run "the_caller_policy_scopes_start_to_the_machine_and_tokens_to_the_wildcard" {
  command = plan

  assert {
    condition     = jsondecode(output.caller_policy_json).Statement[0].Resource == "arn:aws:states:us-west-2:123456789012:stateMachine:example-staging-run"
    error_message = "states:StartExecution must be scoped to this state machine's ARN; a caller policy naming a wildcard there would let the holder start any machine in the account."
  }

  assert {
    condition     = jsondecode(output.caller_policy_json).Statement[1].Resource == "arn:aws:states:us-west-2:123456789012:execution:example-staging-run:*"
    error_message = "DescribeExecution and StopExecution take an execution ARN, not a state machine ARN: the ARN has :execution: in place of :stateMachine: and the execution name appended. A policy naming the state machine ARN for these actions denies every call."
  }

  assert {
    condition     = contains(jsondecode(output.caller_policy_json).Statement[2].Action, "states:SendTaskSuccess")
    error_message = "The caller policy must grant SendTaskSuccess, which is how a worker holding a task token completes a waitForTaskToken state; without it the state waits until its timeout."
  }

  assert {
    condition     = contains(jsondecode(output.caller_policy_json).Statement[2].Action, "states:SendTaskHeartbeat")
    error_message = "SendTaskHeartbeat must be granted: a task with a HeartbeatSeconds set fails the moment a heartbeat is missed, and a worker denied this action cannot keep a long task alive."
  }

  assert {
    condition     = jsondecode(output.caller_policy_json).Statement[2].Resource == "*"
    error_message = "The three task-token actions must be on Resource *, because they authorize against the opaque task token rather than against any ARN; scoping them to the state machine denies every callback."
  }
}

run "a_statement_with_both_actions_and_not_actions_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        actions     = ["ecs:RunTask"]
        not_actions = ["ecs:StopTask"]
        resources   = ["*"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_statement_with_no_resource_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        actions = ["ecs:RunTask"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_duplicated_statement_sid_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      { sid = "Same", actions = ["ecs:RunTask"], resources = ["*"] },
      { sid = "Same", actions = ["ecs:StopTask"], resources = ["*"] },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_statement_effect_iam_does_not_offer_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      { effect = "Permit", actions = ["ecs:RunTask"], resources = ["*"] },
    ]
  }

  expect_failures = [var.policy_statements]
}
