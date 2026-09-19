terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.46, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

module "transaction_search" {
  source = "../../modules/transaction-search"

  name_prefix = "example-staging"

  adopt_spans_log_group = false

  tags = { Name = "example-staging-spans" }
}

output "spans_log_group_name" {
  description = "Reserved log group X-Ray writes spans to."
  value       = module.transaction_search.spans_log_group_name
}

output "trace_segment_destination" {
  description = "Destination X-Ray sends trace segments to."
  value       = module.transaction_search.trace_segment_destination
}
