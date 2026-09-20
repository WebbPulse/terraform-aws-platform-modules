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

module "frontend" {
  source = "../../modules/spa-frontend"

  name    = "example-production-frontend"
  aliases = ["www.example.com", "example.com"]

  acm_certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/00000000-0000-0000-0000-000000000000"

  viewer_request_function = {
    domain         = "example.com"
    canonical_host = "www"
  }
}

output "viewer_request_function_arn" {
  description = "ARN of the function the module built."
  value       = module.frontend.viewer_request_function_arn
}
