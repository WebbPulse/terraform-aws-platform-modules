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

locals {
  name = "example-production"
}

module "state" {
  source = "../../modules/s3-bucket"

  bucket = "${local.name}-terraform-state"

  create_kms_key = true

  lifecycle_rules = {
    expire-noncurrent-state = {
      noncurrent_version_expiration_days     = 365
      newer_noncurrent_versions              = 10
      abort_incomplete_multipart_upload_days = 7
    }

    expire-config-tarballs = {
      prefix          = "configurations/"
      expiration_days = 30
    }
  }

  enable_eventbridge_notifications = true

  tags = {
    Application = local.name
    Component   = "control-plane"
  }
}

resource "aws_iam_role" "workspace" {
  name = "${local.name}-workspace"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "workspace_state" {
  name   = "terraform-state"
  role   = aws_iam_role.workspace.id
  policy = module.state.read_write_policy_json
}

output "backend_configuration" {
  description = "The values a consuming repository's S3 backend block takes. use_lockfile needs Terraform 1.11 or newer and nothing in the bucket policy may block a conditional write."
  value = {
    bucket       = module.state.bucket
    region       = module.state.region
    kms_key_id   = module.state.kms_key_arn
    encrypt      = true
    use_lockfile = true
  }
}
