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

variable "subnet_ids" {
  description = "Public subnet ids the task's ENI is placed in. They must be public subnets with a route to an internet gateway, because the task takes a public IP and there is no NAT gateway to fall back on."
  type        = list(string)
  default     = ["subnet-1111111111111111", "subnet-2222222222222222"]
}

variable "security_group_ids" {
  description = "Security groups for the task's ENI. Egress is what matters; the task needs no inbound rule."
  type        = list(string)
  default     = ["sg-1111111111111111"]
}

module "tasks" {
  source = "../../modules/ecs-fargate"

  cluster_name = "example-staging"

  tasks = {
    plan = {
      image  = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-runner@sha256:1111111111111111111111111111111111111111111111111111111111111111"
      cpu    = "1024"
      memory = "2048"

      ephemeral_storage_size = 40

      environment = {
        TF_IN_AUTOMATION = "true"
        RUN_MODE         = "plan"
      }

      secrets = {
        RUNNER_TOKEN = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/staging/app-AbCdEf:runner_token::"
      }

      task_policy_statements = [
        {
          sid       = "ReadWriteState"
          actions   = ["s3:GetObject", "s3:PutObject"]
          resources = ["arn:aws:s3:::example-staging-terraform-state/*"]
        },
        {
          sid       = "ReportTaskOutcome"
          actions   = ["states:SendTaskSuccess", "states:SendTaskFailure", "states:SendTaskHeartbeat"]
          resources = ["*"]
        },
      ]

      log_retention_days = 14
    }
  }

  tags = { Component = "terraform-runner" }
}

module "run" {
  source = "../../modules/step-functions"

  name = "example-staging-run"

  definition = jsonencode({
    Comment = "Run the Fargate plan task, then wait for the task to report its own outcome."
    StartAt = "RunPlan"
    States = {
      RunPlan = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          Cluster        = "$${ClusterArn}"
          TaskDefinition = "$${PlanTaskDefinitionArn}"
          LaunchType     = "FARGATE"
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = var.subnet_ids
              SecurityGroups = var.security_group_ids
              AssignPublicIp = "ENABLED"
            }
          }
          Overrides = {
            ContainerOverrides = [
              {
                Name = "$${PlanContainerName}"
                Environment = [
                  { Name = "RUN_ID", "Value.$" = "$$.Execution.Name" },
                ]
              },
            ]
          }
        }
        TimeoutSeconds = 3600
        Next           = "AwaitOutcome"
      }

      AwaitOutcome = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage.waitForTaskToken"
        Parameters = {
          QueueUrl = "$${OutcomeQueueUrl}"
          MessageBody = {
            "TaskToken.$" = "$$.Task.Token"
            "RunId.$"     = "$$.Execution.Name"
          }
        }
        HeartbeatSeconds = 300
        TimeoutSeconds   = 3600
        End              = true
      }
    }
  })

  definition_substitutions = {
    ClusterArn            = module.tasks.cluster_arn
    PlanTaskDefinitionArn = module.tasks.task_definition_arns["plan"]
    PlanContainerName     = module.tasks.container_names["plan"]
    OutcomeQueueUrl       = aws_sqs_queue.outcome.url
  }

  policy_statements = [
    {
      sid       = "RunPlanTask"
      actions   = ["ecs:RunTask"]
      resources = ["${module.tasks.task_definition_family_arns["plan"]}:*"]
      condition = {
        ArnEquals = {
          "ecs:cluster" = [module.tasks.cluster_arn]
        }
      }
    },
    {
      sid       = "DescribeAndStopTask"
      actions   = ["ecs:DescribeTasks", "ecs:StopTask"]
      resources = ["*"]
      condition = {
        ArnEquals = {
          "ecs:cluster" = [module.tasks.cluster_arn]
        }
      }
    },
    {
      sid     = "PassTaskRoles"
      actions = ["iam:PassRole"]
      resources = [
        module.tasks.execution_role_arn,
        module.tasks.task_role_arns["plan"],
      ]
      condition = {
        StringEquals = {
          "iam:PassedToService" = ["ecs-tasks.amazonaws.com"]
        }
      }
    },
    {
      sid       = "SendOutcomeMessage"
      actions   = ["sqs:SendMessage"]
      resources = [aws_sqs_queue.outcome.arn]
    },
    {
      sid       = "RunTaskSyncEvents"
      actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
      resources = ["arn:aws:events:us-west-2:123456789012:rule/StepFunctionsGetEventsForECSTaskRule"]
    },
  ]

  log_retention_days = 14
  tags               = { Component = "terraform-runner" }
}

resource "aws_sqs_queue" "outcome" {
  name                      = "example-staging-run-outcome"
  message_retention_seconds = 3600
}

output "state_machine_arn" {
  description = "ARN of the run state machine, which is what the control plane's API calls StartExecution on."
  value       = module.run.arn
}

output "start_execution_policy_json" {
  description = "The policy the API's own role needs to start a run and to complete the task-token wait state."
  value       = module.run.caller_policy_json
}

output "plan_task_definition_arn" {
  description = "Revision-qualified ARN of the plan task definition the state machine launches."
  value       = module.tasks.task_definition_arns["plan"]
}
