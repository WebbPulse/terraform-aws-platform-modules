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

module "ses" {
  source = "../../modules/ses-identity"

  configuration_set_name = "example-transactional"

  domain           = "example.com"
  mail_from_domain = "bounce.example.com"

  verified_recipients = ["owner@example.com"]

  tags = { Name = "example-staging-transactional" }
}

output "configuration_set_name" {
  description = "Configuration set every send names."
  value       = module.ses.configuration_set_name
}

output "dkim_tokens" {
  description = "Easy DKIM tokens to publish as CNAMEs."
  value       = module.ses.dkim_tokens
}

output "send_policy_json" {
  description = "Grant for the sending role."
  value       = module.ses.send_policy_json
}
