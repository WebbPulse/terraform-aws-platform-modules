terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
    }
  }
}

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/example/test/runner"
  retention_in_days = 14
}

module "ecs" {
  source = "../../.."

  cluster_name = "example-test"

  tasks = {
    plan = {
      image  = "example@sha256:aaaa"
      cpu    = "512"
      memory = "1024"

      task_policy_statements = [
        {
          sid       = "WriteRunnerLogs"
          actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          resources = ["${aws_cloudwatch_log_group.runner.arn}:*"]
        },
      ]
    }

    apply = {
      image  = "example@sha256:aaaa"
      cpu    = "512"
      memory = "1024"
    }
  }
}

output "task_role_ids" {
  description = "Task role ids the module created, for the fixture assertions."
  value       = module.ecs.task_role_ids
}

output "task_definition_families" {
  description = "Task definition families the module created, for the fixture assertions."
  value       = module.ecs.task_definition_families
}
