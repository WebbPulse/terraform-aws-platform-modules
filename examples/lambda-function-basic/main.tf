# A Python API function behind an API Gateway HTTP API, the shape both application estates run.
# The module owns the execution role, the log group and the function; the application owns the
# placeholder package and every permission policy on the role.
#
# The seed package here is a local zip built from a directory in the repository. Swap the `code`
# object for the S3 form to seed from an artifacts bucket instead:
#
#   code = {
#     s3_bucket        = aws_s3_bucket.artifacts.id
#     s3_key           = aws_s3_object.placeholder.key
#     source_code_hash = data.archive_file.placeholder.output_base64sha256
#   }
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function"
# with version = "~> 1.6", and the http-api module in front of it with version = "~> 2.0" for the
# integrations map; the relative paths here keep the example runnable from the repository.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

data "archive_file" "placeholder" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_placeholder"
  output_path = "${path.module}/.terraform/lambda_placeholder.zip"
}

module "api_lambda" {
  source = "../../modules/lambda-function"

  function_name = "example-production-api"
  role_name     = "example-production-lambda-api"

  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  architectures = ["arm64"]
  memory_size   = 1024
  timeout       = 29

  code = {
    filename         = data.archive_file.placeholder.output_path
    source_code_hash = data.archive_file.placeholder.output_base64sha256
  }

  environment_variables = {
    APP_ENVIRONMENT = "production"
    LOG_LEVEL       = "INFO"
  }

  log_retention_days    = 14
  log_format            = "JSON"
  application_log_level = "INFO"
  system_log_level      = "INFO"

  tags = { Name = "example-production-api" }
}

# The runtime permissions stay with the application, so each one can grant exactly what its own
# code needs. Attach them to the role by its id.
data "aws_iam_policy_document" "runtime" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${module.api_lambda.log_group_arn}:*"]
  }

  statement {
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "runtime"
  role   = module.api_lambda.role_id
  policy = data.aws_iam_policy_document.runtime.json
}

# The HTTP API in front of it, from the sibling module.
module "api" {
  source = "../../modules/http-api"

  name = "example-production-api"

  integrations = {
    legacy = {
      lambda_function_name = module.api_lambda.function_name
      lambda_invoke_arn    = module.api_lambda.invoke_arn
    }
  }
}
