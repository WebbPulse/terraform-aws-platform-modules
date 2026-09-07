# A versioned, private bucket holding Lambda deployment packages, with a placeholder object the
# function points at until the first real deploy replaces it.
#
# Consumers use source = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-artifacts-bucket"
# with version = "~> 1.6"; the relative path here keeps the example runnable from the repository.

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

locals {
  name = "example-production"
}

# The placeholder zip is built by the caller, not the module, so its path stays put in state.
data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/.terraform/lambda-placeholder.zip"

  source {
    filename = "app/lambda_handler.py"
    content  = <<-PY
      import json


      def handler(event, context):
          return {
              "statusCode": 503,
              "headers": {"Content-Type": "application/json"},
              "body": json.dumps({"detail": "not deployed"}),
          }
    PY
  }
}

module "artifacts" {
  source = "../../modules/lambda-artifacts-bucket"

  bucket = "${local.name}-lambda-artifacts"

  lifecycle_rule_id                      = "expire-noncurrent-artifacts"
  noncurrent_version_expiration_days     = 30
  abort_incomplete_multipart_upload_days = 7

  enable_sse = true

  create_placeholder_object      = true
  placeholder_object_key         = "backend/placeholder.zip"
  placeholder_object_source      = data.archive_file.placeholder.output_path
  placeholder_object_source_hash = data.archive_file.placeholder.output_base64sha256
}

# --- The function that reads from it -----------------------------------------------------------

resource "aws_iam_role" "api" {
  name = "${local.name}-api-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_lambda_function" "api" {
  function_name = "${local.name}-api"
  role          = aws_iam_role.api.arn
  runtime       = "python3.13"
  architectures = ["arm64"]
  handler       = "app.lambda_handler.handler"

  s3_bucket        = module.artifacts.bucket_id
  s3_key           = module.artifacts.placeholder_object_key
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  # CI uploads a new object and updates the function out of band, so Terraform stops tracking
  # which package is live after the first deploy.
  lifecycle {
    ignore_changes = [s3_key, s3_object_version, source_code_hash]
  }
}

output "artifacts_bucket" {
  description = "Bucket name to hand to the deploy pipeline."
  value       = module.artifacts.bucket_id
}

output "placeholder_key" {
  description = "Key of the placeholder package."
  value       = module.artifacts.placeholder_object_key
}
