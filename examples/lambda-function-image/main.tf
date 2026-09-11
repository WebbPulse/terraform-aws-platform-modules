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

  seed_image_uri = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com/example-production/api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

module "api_lambda" {
  source = "../../modules/lambda-function"

  function_name = "example-production-api-image"
  role_name     = "example-production-api-image-lambda"

  package_type = "Image"

  architectures = ["arm64"]
  memory_size   = 1024
  timeout       = 29

  code = {
    image_uri = local.seed_image_uri
  }

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

  tracing_mode = "Active"

  log_retention_days    = 14
  log_format            = "JSON"
  application_log_level = "INFO"
  system_log_level      = "INFO"

  tags = { Name = "example-production-api-image" }
}

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
