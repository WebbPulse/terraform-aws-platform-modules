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

variable "adopt_spans_log_group" {
  description = "Adopt the reserved aws/spans log group. False on a fresh account until one span has been exported."
  type        = bool
  default     = false
}

import {
  for_each = var.adopt_spans_log_group ? toset(["aws/spans"]) : toset([])

  to = module.transaction_search.aws_cloudwatch_log_group.spans[each.key]
  id = each.value
}

module "transaction_search" {
  source = "../../modules/transaction-search"

  name_prefix = "example-staging"

  adopt_spans_log_group = var.adopt_spans_log_group

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
