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

module "tables" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/dynamodb-tables"
  version = "~> 1.6"

  name_prefix = local.prefix

  point_in_time_recovery = local.production
  deletion_protection    = local.production

  tables = {
    users = {
      attributes = [{ name = "id", type = "S" }]
      hash_key   = "id"
    }

    posts = {
      attributes = [
        { name = "id", type = "S" },
        { name = "author_id", type = "S" },
        { name = "created_at", type = "S" },
      ]
      hash_key = "id"

      global_secondary_indexes = [
        {
          name      = "author_id-created_at-index"
          hash_key  = "author_id"
          range_key = "created_at"
        },
      ]
    }

    memberships = {
      attributes = [
        { name = "org_id", type = "S" },
        { name = "user_id", type = "S" },
        { name = "role", type = "S" },
      ]
      hash_key  = "org_id"
      range_key = "user_id"

      global_secondary_indexes = [
        {
          name               = "user_id-org_id-index"
          hash_key           = "user_id"
          range_key          = "org_id"
          projection_type    = "INCLUDE"
          non_key_attributes = ["role"]
        },
      ]
    }

    sessions = {
      attributes             = [{ name = "pk", type = "S" }]
      hash_key               = "pk"
      ttl_attribute          = "expires_at"
      point_in_time_recovery = false
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "tables_rw" {
  statement {
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:UpdateItem",
    ]
    resources = concat(
      module.tables.table_arns_list,
      [for arn in module.tables.table_arns_list : "${arn}/index/*"],
    )
  }
}

output "table_name_environment" {
  description = "Table names keyed by short key, ready to become Lambda environment variables."
  value       = module.tables.table_names
}

output "tables_read_write_policy" {
  description = "Policy document granting item level access to every table and index."
  value       = data.aws_iam_policy_document.tables_rw.json
}
