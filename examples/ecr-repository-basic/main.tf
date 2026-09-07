# An application's whole container registry in one module block: one repository per domain
# function, immutable commit-SHA tags, a lifecycle policy that keeps storage flat, and the IAM
# statement CI needs to push. The Lambda that pulls these images needs no ECR grant at all when it
# lives in this same account; see the note on the push policy below.

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

  # Repositories come out as example-staging/<key>. The slash reads as a namespace, so every
  # repository for one environment sorts together in the console.
  name_prefix = local.prefix

  # One repository per domain function. This is the point of the map: a lifecycle rule that says
  # "keep the last 10 tagged images" then means the last 10 builds of that domain, rather than the
  # last 10 images across every domain sharing a repository.
  repositories = {
    parts       = {}
    users       = {}
    build-lists = {}

    # A domain that deploys far more often than the rest keeps more rollback headroom.
    search = {
      keep_last_tagged_images = 25
    }

    # A domain still being cut over, where CI overwrites a scratch tag rather than pushing a new
    # commit SHA each time. Tag mutability is a repository-level setting, so an image stream that
    # needs a moving tag needs its own repository saying so.
    sandbox = {
      image_tag_mutability = "MUTABLE"
      tag_prefix_list      = ["sha-", "scratch-"]
    }
  }

  # Immutable tags keyed by commit SHA are the default and the shape worth keeping: a tag that
  # cannot move is what makes a deploy reproducible and makes the digest Lambda records meaningful.
  image_tag_mutability = "IMMUTABLE"
  tag_prefix_list      = ["sha-"]

  # Basic scan on push is free and covers operating system package CVEs. Enhanced scanning is
  # Amazon Inspector, set once per registry at the account level, and billed per scan and rescan.
  scan_on_push = true

  # The two numbers that decide cost at rest. Untagged images are the ones that pile up silently,
  # so they go after a day; ten tagged builds is enough to roll back several deploys.
  expire_untagged_after_days = 1
  keep_last_tagged_images    = 10

  # AES256 is the ECR managed key and adds no per-request charge. KMS would add one on every layer
  # upload and pull, for nothing this estate needs.
  encryption_type = "AES256"

  # Staging repositories can be torn down with images still in them; production ones cannot.
  force_delete = !local.production

  tags = {
    Environment = var.environment
    Component   = "container-registry"
  }
}

# CI pushes images. The deploy role needs the repository-scoped actions plus one account-wide
# GetAuthorizationToken, which takes no resource, so it is a separate statement.
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
      # The pull side too, so a build can reuse layers it already pushed.
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]

    resources = module.registry.repository_arns_list
  }
}

# The Lambda that runs one of these images. Note what is absent: no ECR permission on the
# execution role, and no repository policy on the registry. A same-account container-image function
# needs only one side to allow the pull, and Lambda writes that statement onto the repository
# itself when the function is created. Cross-account is the case that needs both sides, and that is
# what the module's repository_policy_principals input is for.
resource "aws_lambda_function" "parts" {
  function_name = "${local.prefix}-parts"
  role          = aws_iam_role.parts.arn
  package_type  = "Image"

  # The image is deployed by CI, which pushes a new commit-SHA tag and calls update-function-code.
  # Terraform creates the function pointing at whatever is current and then stops tracking the tag.
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
