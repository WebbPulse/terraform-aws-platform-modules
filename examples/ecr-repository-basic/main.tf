variable "environment" {
  description = "production or staging"
  type        = string
  default     = "staging"
}

provider "aws" {
  region = "us-west-2"
}

locals {
  prefix     = "example-${var.environment}"
  production = var.environment == "production"
}

module "registry" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ecr-repository"
  version = "~> 1.8"

  name_prefix = local.prefix

  repositories = {
    parts       = {}
    users       = {}
    build-lists = {}

    search = {
      keep_last_tagged_images = 25
    }

    sandbox = {
      image_tag_mutability = "MUTABLE"
      tag_prefix_list      = ["sha-", "scratch-"]
    }
  }

  image_tag_mutability = "IMMUTABLE"
  tag_prefix_list      = ["sha-"]

  scan_on_push = true

  expire_untagged_after_days = 1
  keep_last_tagged_images    = 10

  encryption_type = "AES256"

  force_delete = !local.production

  tags = {
    Environment = var.environment
    Component   = "container-registry"
  }
}

data "aws_iam_policy_document" "ci_push" {
  statement {
    sid       = "GetAuthorizationToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushImages"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]

    resources = module.registry.repository_arns_list
  }
}

resource "aws_lambda_function" "parts" {
  function_name = "${local.prefix}-parts"
  role          = aws_iam_role.parts.arn
  package_type  = "Image"

  image_uri = "${module.registry.repository_urls["parts"]}:sha-0000000000000000000000000000000000000000"

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_iam_role" "parts" {
  name               = "${local.prefix}-parts"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

output "repository_urls" {
  description = "Repository URLs keyed by domain, the map CI reads to know where to push each image."
  value       = module.registry.repository_urls
}

output "registry_id" {
  description = "The registry the repositories live in, which is this account id."
  value       = module.registry.registry_id
}

output "ci_push_policy" {
  description = "Policy document letting a CI role push to every repository the module owns."
  value       = data.aws_iam_policy_document.ci_push.json
}
