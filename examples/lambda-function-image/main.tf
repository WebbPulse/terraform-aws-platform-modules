# A Python API function delivered as a container image rather than a zip, running FastAPI under
# the AWS Lambda Web Adapter. The application process is an ordinary uvicorn server listening on a
# port; the adapter is a Lambda external extension that translates invoke events into HTTP
# requests against it. Nothing in the image imports the Lambda programming model, so the same
# image runs unchanged on Fargate, App Runner or a laptop.
#
# The module owns the execution role, the log group and the function. The image itself is built
# and pushed by CI, and image_uri is under the function's ignore_changes list, so the URI below is
# only a seed: once a pipeline has called UpdateFunctionCode the next plan leaves the running
# image alone.
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function"
# with version = "~> 1.8", and the http-api module in front of it with version = "~> 2.0" for the
# integrations map; the relative paths here keep the example runnable from the repository.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

data "aws_caller_identity" "current" {}

locals {
  region = "us-west-2"

  # Pin the seed to a digest rather than a moving tag. A tag can be repointed underneath a
  # function, and the digest is what makes the deploy recorded in state mean something.
  seed_image_uri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/example-production/api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

module "api_lambda" {
  source = "../../modules/lambda-function"

  function_name = "example-production-api-image"
  role_name     = "example-production-api-image-lambda"

  # An Image function takes neither runtime nor handler: both live in the image. Passing either
  # one alongside package_type = "Image" fails at plan time.
  package_type = "Image"

  architectures = ["arm64"]
  memory_size   = 1024
  timeout       = 29

  code = {
    image_uri = local.seed_image_uri
  }

  # Application configuration. The Web Adapter settings are kept in the separate
  # otel_environment_variables map purely so the two concerns read apart in this call; both maps
  # end up in the same environment block on the function.
  environment_variables = {
    APP_ENVIRONMENT = "production"
    LOG_LEVEL       = "INFO"
  }

  otel_environment_variables = {
    AWS_LWA_PORT                     = "8080"
    AWS_LWA_READINESS_CHECK_PATH     = "/health"
    AWS_LWA_READINESS_CHECK_PROTOCOL = "http"
    AWS_LWA_ASYNC_INIT               = "true"
  }

  # Active tracing plus the module's own inline xray-write policy, which is the default. Without
  # that policy the function samples invocations and then silently fails to publish the segments.
  tracing_mode = "Active"

  log_retention_days    = 14
  log_format            = "JSON"
  application_log_level = "INFO"
  system_log_level      = "INFO"

  tags = { Name = "example-production-api-image" }
}

# Lambda pulls the image as the service, using the function's own resource policy on the
# repository rather than the execution role, so the repository policy names the Lambda service
# principal and scopes it to this account's functions.
data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid    = "LambdaPull"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]

    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values   = ["arn:aws:lambda:${local.region}:${data.aws_caller_identity.current.account_id}:function:*"]
    }
  }
}

resource "aws_ecr_repository_policy" "api" {
  repository = "example-production/api"
  policy     = data.aws_iam_policy_document.ecr_pull.json
}

# The runtime permissions the application's own code needs stay with the application, exactly as
# they do for a zip function. X-Ray is not in this list: the module attaches that itself.
data "aws_iam_policy_document" "runtime" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${module.api_lambda.log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "runtime"
  role   = module.api_lambda.role_id
  policy = data.aws_iam_policy_document.runtime.json
}

# The HTTP API in front of it, from the sibling module. Nothing about the integration changes
# between a zip function and an image function: both are AWS_PROXY integrations on an invoke ARN.
module "api" {
  source = "../../modules/http-api"

  name = "example-production-api-image"

  integrations = {
    legacy = {
      lambda_function_name = module.api_lambda.function_name
      lambda_invoke_arn    = module.api_lambda.invoke_arn
    }
  }
}
