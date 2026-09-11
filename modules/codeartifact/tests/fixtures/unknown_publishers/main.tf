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

  reader_account_ids = [
    "036807648992",
    "621554169154",
    "734702670403",
    "748861776298",
  ]

  publisher_principal_arns = aws_iam_role.publisher[*].arn
}

output "repository_names" {
  description = "Repository names the module created, for the fixture assertions."
  value       = module.codeartifact.repository_names
}

output "consumer_policy_statements" {
  description = "Consumer IAM statements the module produced, for the fixture assertions."
  value       = module.codeartifact.consumer_policy_statements
}
