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

run "a_zip_function_carries_its_runtime_and_handler_and_no_image_uri" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.package_type == "Zip"
    error_message = "package_type must default to Zip: a module that silently defaulted to Image would reject every consumer that passes a runtime and a handler."
  }

  assert {
    condition     = aws_lambda_function.this.runtime == "python3.13"
    error_message = "A Zip function's runtime must reach the function unchanged; it is the only thing that decides which interpreter the deployment package is executed by."
  }

  assert {
    condition     = aws_lambda_function.this.handler == "app.lambda_handler.handler"
    error_message = "A Zip function's handler must reach the function unchanged; Lambda imports exactly this dotted path and a wrong value fails only at the first invoke, not at apply."
  }

  assert {
    condition     = aws_lambda_function.this.image_uri == null
    error_message = "A Zip function must carry no image_uri: the code variable validates that the two shapes are exclusive, and an image_uri on a Zip function is rejected by the service rather than ignored."
  }

  assert {
    condition     = output.package_type == "Zip"
    error_message = "The package_type output echoes the shape so a caller composing on top of this module does not have to repeat the decision; it must match what the function actually got."
  }

  assert {
    condition     = output.image_uri == null
    error_message = "The image_uri output must be empty for a Zip function, because a consumer branching on it to decide whether an ECR repository policy is needed would otherwise create one for a function that never pulls an image."
  }
}

run "a_zip_function_from_s3_names_the_bucket_the_key_and_no_filename" {
  command = plan

  variables {
    code = {
      s3_bucket        = "example-staging-lambda-artifacts"
      s3_key           = "placeholder/api.zip"
      source_code_hash = "3q2+7w=="
    }
  }

  assert {
    condition     = aws_lambda_function.this.s3_bucket == "example-staging-lambda-artifacts"
    error_message = "The S3 shape of code must put the bucket on the function; this is how an estate that builds its seed package into an artifacts bucket delivers the first version."
  }

  assert {
    condition     = aws_lambda_function.this.s3_key == "placeholder/api.zip"
    error_message = "s3_bucket and s3_key are validated as a pair and both must reach the function, because Lambda cannot resolve an object from a bucket name alone."
  }

  assert {
    condition     = aws_lambda_function.this.filename == null
    error_message = "An S3-sourced function must carry no filename: setting both would make it ambiguous which package Terraform seeds the function with."
  }
}

run "an_image_function_takes_the_uri_and_leaves_runtime_and_handler_unset" {
  command = plan

  variables {
    package_type = "Image"
    runtime      = null
    handler      = null

    architectures = ["arm64"]

    code = {
      image_uri = "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    }
  }

  assert {
    condition     = aws_lambda_function.this.package_type == "Image"
    error_message = "package_type must reach the function: this is the attribute that decides whether Lambda expects a zip in S3 or pulls a container image from ECR, and it is not inferred from the presence of an image_uri."
  }

  assert {
    condition     = aws_lambda_function.this.image_uri == "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    error_message = "The seed image_uri must reach the function; it is the only thing that gives the function a first runnable image before CI has ever called UpdateFunctionCode."
  }

  assert {
    condition     = aws_lambda_function.this.runtime == null
    error_message = "An Image function must carry no runtime: the container image supplies the interpreter, and passing one alongside package_type Image is rejected by the service."
  }

  assert {
    condition     = aws_lambda_function.this.handler == null
    error_message = "An Image function must carry no handler: the image's CMD, or the image_config block, plays that role instead."
  }

  assert {
    condition     = output.image_uri == "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    error_message = "The image_uri output must echo the seed value, because a consumer wiring an ECR repository policy or an alarm needs to know which repository this function pulls from."
  }

  assert {
    condition     = one(aws_lambda_function.this.architectures) == "arm64"
    error_message = "architectures must reach the function: an arm64 function handed an x86_64 image fails at the first invoke with an exec format error rather than at apply, so the value has to be plumbed, not defaulted."
  }
}

run "image_config_is_absent_unless_a_consumer_overrides_the_images_own_cmd" {
  command = plan

  variables {
    package_type = "Image"
    runtime      = null
    handler      = null

    code = {
      image_uri = "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    }
  }

  assert {
    condition     = length(aws_lambda_function.this.image_config) == 0
    error_message = "image_config defaults to null and must leave the block out entirely, so an image that already declares its own CMD keeps it; an empty block would override the Dockerfile with nothing."
  }
}

run "image_config_reaches_the_function_when_a_consumer_sets_a_command" {
  command = plan

  variables {
    package_type = "Image"
    runtime      = null
    handler      = null

    image_config = {
      command = ["app.consumers.handler"]
    }

    code = {
      image_uri = "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    }
  }

  assert {
    condition     = length(aws_lambda_function.this.image_config) == 1
    error_message = "A non-null image_config must produce exactly one block; this is how one shared image serves several stream consumers by being pointed at a different entry point per function."
  }

  assert {
    condition     = one(aws_lambda_function.this.image_config).command == tolist(["app.consumers.handler"])
    error_message = "The command override must reach the function verbatim, because it is what selects which handler inside a shared image this function runs."
  }
}

run "a_zip_function_without_a_runtime_is_rejected" {
  command = plan

  variables {
    runtime = null
  }

  expect_failures = [var.runtime]
}

run "an_image_function_that_also_passes_a_runtime_is_rejected" {
  command = plan

  variables {
    package_type = "Image"
    handler      = null

    code = {
      image_uri = "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    }
  }

  expect_failures = [var.runtime]
}

run "a_zip_function_without_a_handler_is_rejected" {
  command = plan

  variables {
    handler = null
  }

  expect_failures = [var.handler]
}

run "an_image_function_that_also_passes_a_handler_is_rejected" {
  command = plan

  variables {
    package_type = "Image"
    runtime      = null

    code = {
      image_uri = "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    }
  }

  expect_failures = [var.handler]
}

run "code_that_names_two_sources_at_once_is_rejected" {
  command = plan

  variables {
    code = {
      filename  = "placeholder.zip"
      s3_bucket = "example-staging-lambda-artifacts"
      s3_key    = "placeholder/api.zip"
    }
  }

  expect_failures = [var.code]
}

run "code_that_names_no_source_at_all_is_rejected" {
  command = plan

  variables {
    code = {
      source_code_hash = "3q2+7w=="
    }
  }

  expect_failures = [var.code]
}

run "an_s3_bucket_without_an_s3_key_is_rejected" {
  command = plan

  variables {
    code = {
      s3_bucket = "example-staging-lambda-artifacts"
    }
  }

  expect_failures = [var.code]
}

run "an_image_uri_on_a_zip_function_is_rejected" {
  command = plan

  variables {
    code = {
      image_uri = "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    }
  }

  expect_failures = [var.code]
}

run "an_image_config_that_overrides_nothing_is_rejected" {
  command = plan

  variables {
    package_type = "Image"
    runtime      = null
    handler      = null

    image_config = {}

    code = {
      image_uri = "111122223333.dkr.ecr.us-west-2.amazonaws.com/example-staging/api@sha256:aaaabbbbccccddddeeeeffff00001111222233334444555566667777888899990"
    }
  }

  expect_failures = [var.image_config]
}

run "a_package_type_outside_zip_and_image_is_rejected" {
  command = plan

  variables {
    package_type = "Container"
  }

  expect_failures = [var.package_type]
}

run "two_architectures_at_once_are_rejected" {
  command = plan

  variables {
    architectures = ["x86_64", "arm64"]
  }

  expect_failures = [var.architectures]
}

run "an_architecture_lambda_does_not_offer_is_rejected" {
  command = plan

  variables {
    architectures = ["aarch64"]
  }

  expect_failures = [var.architectures]
}
