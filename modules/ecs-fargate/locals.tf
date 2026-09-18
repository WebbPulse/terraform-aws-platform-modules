locals {
  execution_role_name   = coalesce(var.execution_role_name, "${var.cluster_name}-task-execution")
  task_role_name_prefix = coalesce(var.task_role_name_prefix, var.cluster_name)
  log_group_name_prefix = coalesce(var.log_group_name_prefix, "/aws/ecs/${var.cluster_name}")

  tasks = {
    for k, t in var.tasks : k => merge(t, {
      family         = coalesce(t.family, "${var.cluster_name}-${k}")
      container_name = coalesce(t.container_name, k)
      log_group_name = coalesce(t.log_group_name, "${local.log_group_name_prefix}/${k}")
      task_role_name = "${local.task_role_name_prefix}-${k}"
    })
  }

  secret_arns = distinct(flatten([
    for k, t in var.tasks : [for name, arn in t.secrets : arn]
  ]))

  secretsmanager_arns = [for arn in local.secret_arns : arn if can(regex("^arn:[a-z0-9-]+:secretsmanager:", arn))]
  ssm_arns            = [for arn in local.secret_arns : arn if can(regex("^arn:[a-z0-9-]+:ssm:", arn))]

  secretsmanager_policy_arns = sort(distinct([
    for arn in local.secretsmanager_arns :
    join(":", slice(split(":", arn), 0, 7))
  ]))

  ssm_policy_arns = sort(distinct(local.ssm_arns))

  execution_role_statements = concat(
    length(local.secretsmanager_policy_arns) > 0 ? [{
      Sid      = "ReadTaskSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = jsondecode(length(local.secretsmanager_policy_arns) == 1 ? jsonencode(local.secretsmanager_policy_arns[0]) : jsonencode(local.secretsmanager_policy_arns))
    }] : [],
    length(local.ssm_policy_arns) > 0 ? [{
      Sid      = "ReadTaskParameters"
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = jsondecode(length(local.ssm_policy_arns) == 1 ? jsonencode(local.ssm_policy_arns[0]) : jsonencode(local.ssm_policy_arns))
    }] : [],
    local.rendered_execution_statements,
  )

  rendered_execution_statements = [
    for s in var.execution_role_policy_statements : merge(
      s.sid == null ? {} : { Sid = s.sid },
      { Effect = s.effect },
      s.actions == null ? {} : { Action = jsondecode(length(s.actions) == 1 ? jsonencode(s.actions[0]) : jsonencode(s.actions)) },
      s.not_actions == null ? {} : { NotAction = jsondecode(length(s.not_actions) == 1 ? jsonencode(s.not_actions[0]) : jsonencode(s.not_actions)) },
      s.resources == null ? {} : { Resource = jsondecode(length(s.resources) == 1 ? jsonencode(s.resources[0]) : jsonencode(s.resources)) },
      s.not_resources == null ? {} : { NotResource = jsondecode(length(s.not_resources) == 1 ? jsonencode(s.not_resources[0]) : jsonencode(s.not_resources)) },
      s.condition == null ? {} : {
        Condition = {
          for op, kv in s.condition : op => {
            for key, v in kv : key => jsondecode(length(v) == 1 ? jsonencode(v[0]) : jsonencode(v))
          }
        }
      },
    )
  ]

  task_policy_statements = {
    for k, t in var.tasks : k => [
      for s in t.task_policy_statements : merge(
        s.sid == null ? {} : { Sid = s.sid },
        { Effect = s.effect },
        s.actions == null ? {} : { Action = jsondecode(length(s.actions) == 1 ? jsonencode(s.actions[0]) : jsonencode(s.actions)) },
        s.not_actions == null ? {} : { NotAction = jsondecode(length(s.not_actions) == 1 ? jsonencode(s.not_actions[0]) : jsonencode(s.not_actions)) },
        s.resources == null ? {} : { Resource = jsondecode(length(s.resources) == 1 ? jsonencode(s.resources[0]) : jsonencode(s.resources)) },
        s.not_resources == null ? {} : { NotResource = jsondecode(length(s.not_resources) == 1 ? jsonencode(s.not_resources[0]) : jsonencode(s.not_resources)) },
        s.condition == null ? {} : {
          Condition = {
            for op, kv in s.condition : op => {
              for key, v in kv : key => jsondecode(length(v) == 1 ? jsonencode(v[0]) : jsonencode(v))
            }
          }
        },
      )
    ]
  }

  tasks_with_policies = {
    for k, statements in local.task_policy_statements : k => statements if length(statements) > 0
  }

  task_definition_arns = {
    for k, d in aws_ecs_task_definition.this : k => d.arn
  }

  task_definition_family_arns = {
    for k, d in aws_ecs_task_definition.this : k => "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task-definition/${d.family}"
  }

  run_task_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunTask"
        Effect   = "Allow"
        Action   = "ecs:RunTask"
        Resource = sort([for k, arn in local.task_definition_family_arns : "${arn}:*"])
        Condition = {
          ArnEquals = {
            "ecs:cluster" = aws_ecs_cluster.this.arn
          }
        }
      },
      {
        Sid      = "DescribeAndStopTask"
        Effect   = "Allow"
        Action   = ["ecs:DescribeTasks", "ecs:StopTask"]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "ecs:cluster" = aws_ecs_cluster.this.arn
          }
        }
      },
      {
        Sid    = "PassTaskRoles"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = sort(distinct(concat(
          [aws_iam_role.execution.arn],
          [for k, r in aws_iam_role.task : r.arn],
        )))
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
    ]
  })
}
