variables {
  function_name = "example-staging-api"

  runtime = "python3.13"
  handler = "app.lambda_handler.handler"

  code = {
    filename         = "placeholder.zip"
    source_code_hash = "3q2+7w=="
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

run "the_role_name_defaults_to_the_function_name_with_a_role_suffix" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "example-staging-api-role"
    error_message = "With role_name left null the execution role must be named <function_name>-role; a consumer that never names the role relies on that being stable, because changing the name replaces the role and every policy attached to it."
  }

  assert {
    condition     = aws_iam_role.this.path == "/"
    error_message = "role_path must default to the account root path, which is where an IAM role created without a path lives; a different default would move every adopting consumer's role and force a replacement."
  }

  assert {
    condition     = aws_iam_role.this.description == null
    error_message = "role_description must default to null so an estate whose roles have no description in state sees an empty plan when it adopts this module."
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "No permissions boundary may be set unless a consumer asks for one: a boundary attached by surprise silently narrows every policy the application later attaches to this role."
  }
}

run "an_explicit_role_name_and_path_reach_the_role" {
  command = plan

  variables {
    role_name        = "example-staging-lambda-api"
    role_path        = "/service/"
    role_description = "Execution role for the example staging API"

    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/example-staging-boundary"

    role_tags = {
      Component = "api"
    }
  }

  assert {
    condition     = aws_iam_role.this.name == "example-staging-lambda-api"
    error_message = "An explicit role_name must win over the derived default; both consuming estates name their roles by hand because their historical names do not follow the <function_name>-role pattern."
  }

  assert {
    condition     = aws_iam_role.this.path == "/service/"
    error_message = "role_path must reach the role, because it is part of the role ARN and a policy written against the wrong path denies nothing and grants nothing."
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == "arn:aws:iam::123456789012:policy/example-staging-boundary"
    error_message = "permissions_boundary_arn must reach the role: an estate that requires boundaries on every role gets a role creation denied by its own SCP if the module drops the value."
  }

  assert {
    condition     = aws_iam_role.this.tags["Component"] == "api"
    error_message = "role_tags must land on the role alone; they are a separate input from tags precisely so a consumer can tag the role and the function differently without one leaking into the other."
  }

  assert {
    condition     = length(var.tags) == 0
    error_message = "role_tags must not leak onto the function: tags on a Lambda function drive cost allocation and alarm selection, and silently copying the role's tags there changes what a consumer's reports count."
  }
}

run "the_trust_policy_names_only_the_lambda_service_by_default" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "The trust policy must be exactly one statement; every additional statement is another way into the role and has to be a deliberate consumer choice."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Service == "lambda.amazonaws.com"
    error_message = "The default trust policy must name lambda.amazonaws.com and nothing else: it is the principal the function itself assumes, and anything wider is a role a second service can wear."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRole"
    error_message = "The trust statement must grant sts:AssumeRole; without it Lambda cannot start the function and the failure surfaces as an invoke-time error rather than at apply."
  }
}

run "an_edge_function_can_add_the_second_service_principal" {
  command = plan

  variables {
    assume_role_service_principals = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Service) == 2
    error_message = "Both principals must land in one statement, because a Lambda@Edge function is assumed by edgelambda.amazonaws.com at the edge and by lambda.amazonaws.com in the origin region, and dropping either one breaks half the invocations."
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Service, "edgelambda.amazonaws.com")
    error_message = "edgelambda.amazonaws.com must reach the trust policy verbatim; it is the only principal that can assume the role from a CloudFront edge location."
  }
}

run "an_empty_principal_list_is_rejected" {
  command = plan

  variables {
    assume_role_service_principals = []
  }

  expect_failures = [var.assume_role_service_principals]
}

run "a_duplicated_principal_is_rejected" {
  command = plan

  variables {
    assume_role_service_principals = ["lambda.amazonaws.com", "lambda.amazonaws.com"]
  }

  expect_failures = [var.assume_role_service_principals]
}

run "a_role_path_without_surrounding_slashes_is_rejected" {
  command = plan

  variables {
    role_path = "service"
  }

  expect_failures = [var.role_path]
}

run "a_function_name_with_a_character_lambda_rejects_is_rejected" {
  command = plan

  variables {
    function_name = "example staging api"
  }

  expect_failures = [var.function_name]
}

run "a_role_name_with_a_character_iam_rejects_is_rejected" {
  command = plan

  variables {
    role_name = "example/staging/api"
  }

  expect_failures = [var.role_name]
}

run "active_tracing_attaches_the_xray_write_policy_by_default" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.tracing_config[0].mode == "Active"
    error_message = "tracing_mode must default to Active: a function whose traces are off by default is a function nobody notices is untraced until an incident."
  }

  assert {
    condition     = length(aws_iam_role_policy.xray_write) == 1
    error_message = "Active tracing without X-Ray write permission is the trap this module exists to close: the service samples the invoke, the runtime tries to publish the segment, the call is denied silently, and the traces simply never appear."
  }

  assert {
    condition     = output.xray_write_policy_attached
    error_message = "The xray_write_policy_attached output must report true here, because a consumer reads it to decide whether its own runtime policy still has to carry the two X-Ray actions."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.xray_write[0].policy).Statement[0].Action == ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    error_message = "The inline policy must grant exactly PutTraceSegments and PutTelemetryRecords: the managed AWSXRayDaemonWriteAccess adds three sampling actions that a Lambda function never calls, because the service makes the sampling decision before the invoke."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.xray_write[0].policy).Statement[0].Resource == "*"
    error_message = "Resource must be * because neither X-Ray action takes resource-level permissions; that is a property of the X-Ray IAM surface rather than a wildcard chosen for convenience."
  }
}

run "an_estate_that_already_grants_xray_can_turn_the_policy_off" {
  command = plan

  variables {
    attach_xray_write_policy = false
  }

  assert {
    condition     = length(aws_iam_role_policy.xray_write) == 0
    error_message = "attach_xray_write_policy false must create no inline policy, so an estate that carried the two X-Ray actions in its own runtime policy before this module existed does not end up with a duplicate grant it has to reason about."
  }

  assert {
    condition     = !output.xray_write_policy_attached
    error_message = "The output must report false when the policy is turned off, otherwise a consumer branching on it drops its own grant and the function loses X-Ray write access entirely."
  }

  assert {
    condition     = aws_lambda_function.this.tracing_config[0].mode == "Active"
    error_message = "Turning the policy off must not turn tracing off: the two are separate decisions, and an estate opting out of the grant still wants Active sampling."
  }
}

run "passthrough_tracing_skips_the_policy_without_an_opt_out" {
  command = plan

  variables {
    tracing_mode = "PassThrough"
  }

  assert {
    condition     = aws_lambda_function.this.tracing_config[0].mode == "PassThrough"
    error_message = "PassThrough must reach the function; it is what makes the function continue an upstream trace without starting one of its own."
  }

  assert {
    condition     = length(aws_iam_role_policy.xray_write) == 0
    error_message = "The X-Ray grant must be skipped automatically whenever tracing is not Active, so PassThrough needs no separate opt out and never leaves a permission on a role that has nothing to publish."
  }
}

run "null_tracing_leaves_the_block_out_entirely" {
  command = plan

  variables {
    tracing_mode = null
  }

  assert {
    condition     = var.tracing_mode == null
    error_message = "A null tracing_mode must leave the tracing_config block out rather than writing a block with a null mode, because the service reads an absent block as PassThrough and a consumer adopting the module with no block in state would otherwise see a diff."
  }

  assert {
    condition     = length(aws_iam_role_policy.xray_write) == 0
    error_message = "With no tracing_config there is nothing to publish, so the X-Ray grant must be skipped here too."
  }
}

run "a_tracing_mode_xray_does_not_offer_is_rejected" {
  command = plan

  variables {
    tracing_mode = "Enabled"
  }

  expect_failures = [var.tracing_mode]
}

run "the_role_outputs_are_the_three_shapes_a_consumer_attaches_policies_with" {
  command = plan

  variables {
    role_name = "example-staging-lambda-api"
  }

  override_resource {
    target          = aws_iam_role.this
    override_during = plan
    values = {
      id        = "example-staging-lambda-api"
      arn       = "arn:aws:iam::123456789012:role/example-staging-lambda-api"
      unique_id = "AROAEXAMPLEUNIQUEID12"
    }
  }

  assert {
    condition     = output.role_name == "example-staging-lambda-api"
    error_message = "role_name is what an aws_iam_role_policy_attachment outside the module takes, so it must be the plain name rather than an ARN."
  }

  assert {
    condition     = output.role_id == "example-staging-lambda-api"
    error_message = "role_id is the value aws_iam_role_policy takes as its role argument, and it is the output both consuming estates use to attach their runtime policies; anything else there breaks every application permission at once."
  }

  assert {
    condition     = output.role_arn == "arn:aws:iam::123456789012:role/example-staging-lambda-api"
    error_message = "role_arn is what a policy elsewhere names as a principal, for example a KMS key policy or a cross-account trust, so it must be the full ARN of the role this module created."
  }

  assert {
    condition     = output.role_unique_id == "AROAEXAMPLEUNIQUEID12"
    error_message = "role_unique_id must be the role's stable unique id, which is the only value usable in an aws:userId condition that survives the role being recreated under the same name."
  }
}
