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

module "jobs_queue" {
  source = "../../modules/sqs-queue"

  name = "example-staging-jobs"

  consumer_timeout_seconds   = 30
  visibility_timeout_seconds = 180
  max_receive_count          = 5

  producer_role_arns = [module.api_lambda.role_arn]

  tags = { Name = "example-staging-jobs" }
}

module "api_lambda" {
  source = "../../modules/lambda-function"

  function_name = "example-staging-api"
  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  timeout       = 29

  code = {
    filename         = data.archive_file.placeholder.output_path
    source_code_hash = data.archive_file.placeholder.output_base64sha256
  }
}

module "worker_lambda" {
  source = "../../modules/lambda-function"

  function_name = "example-staging-worker"
  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  timeout       = 30

  code = {
    filename         = data.archive_file.placeholder.output_path
    source_code_hash = data.archive_file.placeholder.output_base64sha256
  }

  sqs_event_sources = {
    jobs = {
      queue_arn           = module.jobs_queue.queue_arn
      maximum_concurrency = 20
    }
  }
}

output "queue_url" {
  description = "URL the API Lambda sends jobs to."
  value       = module.jobs_queue.queue_url
}

output "dead_letter_queue_name" {
  description = "Dead letter queue name, which is the QueueName dimension for an alarm on parked messages."
  value       = module.jobs_queue.dead_letter_queue_name
}

output "events_path" {
  description = "Path the worker's Web Adapter posts each SQS batch to."
  value       = module.worker_lambda.events_path
}
