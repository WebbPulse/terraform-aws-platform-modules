# The regression harness for the repository policy type unification bug.
#
# It wraps the module under test next to the IAM roles whose ARNs it publishes with, in one
# configuration and therefore one plan graph. That is the whole point: an ARN read off an
# aws_iam_role that does not exist yet is unknown at plan time, which is the condition the module
# used to fail on. Passing literal ARNs, as every other example does, never reaches the bug.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
    }
  }
}

variable "publisher_role_count" {
  description = "How many publisher roles to create. One renders Principal.AWS as a bare string, two as a list, and both shapes have to plan."
  type        = number
  default     = 2
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "publisher" {
  count = var.publisher_role_count

  name               = "example-test-publisher-${count.index}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

module "codeartifact" {
  source = "../../.."

  domain = "example-test-domain"

  repositories = {
    "pypi-store" = {
      description          = "Proxy of the public PyPI registry."
      external_connections = ["public:pypi"]
    }
    "python" = {
      description = "First-party Python packages."
      upstreams   = ["pypi-store"]
    }
    "shared" = {
      description = "Fan-in endpoint."
      upstreams   = ["python"]
    }
  }

  # Four reader accounts, as the real estate has. This matters: with one reader the read statement's
  # Principal.AWS is a plain string and unifies with anything, so the bug stays hidden. With four it
  # is a tuple of four strings, which is the type the failing run reported against the unknown
  # publisher side.
  reader_account_ids = [
    "036807648992",
    "621554169154",
    "734702670403",
    "748861776298",
  ]

  # Unknown at plan time, which is the condition under test.
  publisher_principal_arns = aws_iam_role.publisher[*].arn
}

output "repository_names" {
  value = module.codeartifact.repository_names
}

output "consumer_policy_statements" {
  value = module.codeartifact.consumer_policy_statements
}
