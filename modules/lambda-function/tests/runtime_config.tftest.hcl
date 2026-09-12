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

run "the_environment_block_is_absent_when_there_are_no_variables" {
  command = plan

  assert {
    condition     = length(aws_lambda_function.this.environment) == 0
    error_message = "An empty environment_variables map must leave the environment block out entirely rather than writing an empty block; the two are different in state and an estate with no block would otherwise see a diff on adoption."
  }

  assert {
    condition     = length(aws_lambda_function.this.vpc_config) == 0
    error_message = "vpc_config defaults to null, and a function outside a VPC must carry no vpc_config block; attaching one by default would require network permissions on the role the module does not grant."
  }

  assert {
    condition     = var.ephemeral_storage_size == null
    error_message = "ephemeral_storage_size must default to null so the block is left out entirely, which the service reads as the 512 MB default; an explicit block is a diff for every consumer that never asked for more /tmp."
  }

  assert {
    condition     = length(aws_lambda_function.this.layers) == 0
    error_message = "layers must default to empty: a layer attached by surprise changes the import path the runtime resolves against and can shadow a package the application ships itself."
  }
}

run "the_otel_variables_are_merged_over_the_application_ones" {
  command = plan

  variables {
    environment_variables = {
      ENVIRONMENT  = "staging"
      SERVICE_NAME = "example-api"
      LOG_LEVEL    = "INFO"
    }

    otel_environment_variables = {
      LOG_LEVEL                          = "DEBUG"
      OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = "https://xray.us-west-2.amazonaws.com/v1/traces"
    }
  }

  assert {
    condition     = length(aws_lambda_function.this.environment) == 1
    error_message = "Any non-empty merged map must produce exactly one environment block; the two inputs are a presentation convenience in the module call and must not become two blocks, which the service does not accept."
  }

  assert {
    condition     = one(aws_lambda_function.this.environment).variables["ENVIRONMENT"] == "staging"
    error_message = "A key set only in environment_variables must survive the merge, otherwise splitting tracing configuration into its own input would quietly drop application configuration."
  }

  assert {
    condition     = one(aws_lambda_function.this.environment).variables["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] == "https://xray.us-west-2.amazonaws.com/v1/traces"
    error_message = "A key set only in otel_environment_variables must reach the function; it is the endpoint the runtime posts spans to and an absent value means no traces at all."
  }

  assert {
    condition     = one(aws_lambda_function.this.environment).variables["LOG_LEVEL"] == "DEBUG"
    error_message = "A key set in both maps must take the value from otel_environment_variables, because that map is documented as merged on top and a consumer overriding a shared key relies on that direction."
  }

  assert {
    condition     = length(one(aws_lambda_function.this.environment).variables) == 4
    error_message = "The merged environment must hold the union of the two maps with the shared key counted once, so a consumer can predict exactly what the function sees."
  }
}

run "otel_variables_alone_are_enough_to_create_the_environment_block" {
  command = plan

  variables {
    otel_environment_variables = {
      AWS_LWA_PORT = "8080"
    }
  }

  assert {
    condition     = length(aws_lambda_function.this.environment) == 1
    error_message = "The block's presence is decided by the merged map, not by environment_variables alone; a consumer that puts everything in otel_environment_variables must still get an environment block."
  }

  assert {
    condition     = one(aws_lambda_function.this.environment).variables["AWS_LWA_PORT"] == "8080"
    error_message = "The Lambda Web Adapter reads its configuration from ordinary environment variables, so a value passed through this input has to arrive intact; a mismatched port presents as a timeout rather than as an error."
  }
}

run "memory_timeout_and_concurrency_reach_the_function" {
  command = plan

  variables {
    memory_size = 1024
    timeout     = 29

    reserved_concurrent_executions = 5

    description = "Example staging API"

    tags = {
      Name = "example-staging-api"
    }
  }

  assert {
    condition     = aws_lambda_function.this.memory_size == 1024
    error_message = "memory_size must reach the function: it also sets the CPU share, so it is the single knob that decides both cost and cold start time for every domain function."
  }

  assert {
    condition     = aws_lambda_function.this.timeout == 29
    error_message = "timeout must reach the function; behind an API Gateway HTTP API 29 seconds is the integration's own ceiling, and a function allowed to run longer just burns the extra time after the gateway has already answered 504."
  }

  assert {
    condition     = aws_lambda_function.this.reserved_concurrent_executions == 5
    error_message = "reserved_concurrent_executions must reach the function; a reservation caps this function and simultaneously removes that capacity from the account pool every other function shares."
  }

  assert {
    condition     = aws_lambda_function.this.description == "Example staging API"
    error_message = "description must reach the function so a console reader can tell two similarly named functions apart."
  }

  assert {
    condition     = aws_lambda_function.this.tags["Name"] == "example-staging-api"
    error_message = "tags must land on the function; both consuming estates set a Name tag there and it is what their cost reports group by."
  }
}

run "no_reservation_is_the_default" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.reserved_concurrent_executions == -1
    error_message = "With reserved_concurrent_executions null the function must carry no reservation, which the provider represents as -1; a reservation applied by default would cap a function nobody asked to cap and drain the shared account pool."
  }

  assert {
    condition     = !aws_lambda_function.this.publish
    error_message = "publish must default to off: both estates deploy code out of band, and publishing a numbered version on every configuration change accumulates immutable versions nothing ever invokes."
  }
}

run "publishing_versions_is_available_for_an_estate_that_wants_them" {
  command = plan

  variables {
    publish = true
  }

  assert {
    condition     = aws_lambda_function.this.publish
    error_message = "publish must reach the function, because it is what makes qualified_arn and version point at anything other than $LATEST."
  }
}

run "a_memory_size_below_the_lambda_floor_is_rejected" {
  command = plan

  variables {
    memory_size = 64
  }

  expect_failures = [var.memory_size]
}

run "a_memory_size_above_the_lambda_ceiling_is_rejected" {
  command = plan

  variables {
    memory_size = 10496
  }

  expect_failures = [var.memory_size]
}

run "a_timeout_above_the_lambda_ceiling_is_rejected" {
  command = plan

  variables {
    timeout = 901
  }

  expect_failures = [var.timeout]
}

run "a_timeout_of_zero_is_rejected" {
  command = plan

  variables {
    timeout = 0
  }

  expect_failures = [var.timeout]
}

run "a_reservation_below_minus_one_is_rejected" {
  command = plan

  variables {
    reserved_concurrent_executions = -2
  }

  expect_failures = [var.reserved_concurrent_executions]
}

run "more_layers_than_lambda_accepts_is_rejected" {
  command = plan

  variables {
    layers = [
      "arn:aws:lambda:us-west-2:123456789012:layer:one:1",
      "arn:aws:lambda:us-west-2:123456789012:layer:two:1",
      "arn:aws:lambda:us-west-2:123456789012:layer:three:1",
      "arn:aws:lambda:us-west-2:123456789012:layer:four:1",
      "arn:aws:lambda:us-west-2:123456789012:layer:five:1",
      "arn:aws:lambda:us-west-2:123456789012:layer:six:1",
    ]
  }

  expect_failures = [var.layers]
}

run "a_vpc_function_carries_both_subnets_and_security_groups" {
  command = plan

  variables {
    vpc_config = {
      subnet_ids         = ["subnet-11111111111111111", "subnet-22222222222222222"]
      security_group_ids = ["sg-33333333333333333"]
    }

    ephemeral_storage_size = 2048

    layers = ["arn:aws:lambda:us-west-2:123456789012:layer:example:1"]
  }

  assert {
    condition     = length(aws_lambda_function.this.vpc_config) == 1
    error_message = "A non-null vpc_config must produce exactly one block; the function cannot reach a private subnet without it."
  }

  assert {
    condition     = length(one(aws_lambda_function.this.vpc_config).subnet_ids) == 2
    error_message = "Every subnet must reach the function: dropping one silently halves the availability zones the function's network interfaces are spread across."
  }

  assert {
    condition     = one(one(aws_lambda_function.this.vpc_config).security_group_ids) == "sg-33333333333333333"
    error_message = "The security group must reach the function; it is the only thing deciding what the function can talk to once it is inside the VPC."
  }

  assert {
    condition     = one(aws_lambda_function.this.ephemeral_storage).size == 2048
    error_message = "ephemeral_storage_size must reach the function when set, because a workload that writes more than 512 MB to /tmp fails at runtime with no space left on device rather than at apply."
  }

  assert {
    condition     = one(aws_lambda_function.this.layers) == "arn:aws:lambda:us-west-2:123456789012:layer:example:1"
    error_message = "Layers must reach the function in the order given; layer order decides which copy of a shadowed package the runtime resolves."
  }
}

run "a_vpc_config_with_no_subnets_is_rejected" {
  command = plan

  variables {
    vpc_config = {
      subnet_ids         = []
      security_group_ids = ["sg-33333333333333333"]
    }
  }

  expect_failures = [var.vpc_config]
}

run "a_vpc_config_with_no_security_groups_is_rejected" {
  command = plan

  variables {
    vpc_config = {
      subnet_ids         = ["subnet-11111111111111111"]
      security_group_ids = []
    }
  }

  expect_failures = [var.vpc_config]
}

run "an_ephemeral_storage_size_below_the_floor_is_rejected" {
  command = plan

  variables {
    ephemeral_storage_size = 256
  }

  expect_failures = [var.ephemeral_storage_size]
}

run "an_ephemeral_storage_size_above_the_ceiling_is_rejected" {
  command = plan

  variables {
    ephemeral_storage_size = 20480
  }

  expect_failures = [var.ephemeral_storage_size]
}

run "the_function_outputs_are_the_shapes_the_gateway_and_alarms_consume" {
  command = plan

  override_resource {
    target          = aws_lambda_function.this
    override_during = plan
    values = {
      arn                  = "arn:aws:lambda:us-west-2:123456789012:function:example-staging-api"
      invoke_arn           = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-staging-api/invocations"
      qualified_arn        = "arn:aws:lambda:us-west-2:123456789012:function:example-staging-api:$LATEST"
      qualified_invoke_arn = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-staging-api:$LATEST/invocations"
      version              = "$LATEST"
    }
  }

  assert {
    condition     = output.function_name == "example-staging-api"
    error_message = "function_name is the alarm dimension and the target of a deployment pipeline's UpdateFunctionCode call, so it must be the bare name rather than an ARN."
  }

  assert {
    condition     = output.function_arn == "arn:aws:lambda:us-west-2:123456789012:function:example-staging-api"
    error_message = "function_arn must be the unqualified ARN of the function this module created; it is the resource of a lambda:UpdateFunctionCode policy statement and of the event source mapping a stream consumer is wired through."
  }

  assert {
    condition     = output.invoke_arn == "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-staging-api/invocations"
    error_message = "invoke_arn is what the http-api module takes as lambda_invoke_arn for an AWS_PROXY integration; it is a different shape from the function ARN and the gateway rejects the wrong one."
  }

  assert {
    condition     = output.version == "$LATEST"
    error_message = "version must come from the function itself so a consumer can tell whether publishing is on without reading the input back."
  }

  assert {
    condition     = output.qualified_arn == "arn:aws:lambda:us-west-2:123456789012:function:example-staging-api:$LATEST"
    error_message = "qualified_arn must come from the function rather than being assembled by hand, because it is empty unless publish is on and a hand-built value would look valid while pointing at a version that does not exist."
  }

  assert {
    condition     = output.qualified_invoke_arn == "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/arn:aws:lambda:us-west-2:123456789012:function:example-staging-api:$LATEST/invocations"
    error_message = "qualified_invoke_arn is the version-pinned integration target, and pointing a gateway at a stale or invented one sends live traffic to code nobody deployed."
  }
}
