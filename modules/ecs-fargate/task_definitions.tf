resource "aws_ecs_task_definition" "this" {
  for_each = local.tasks

  family                   = each.value.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task[each.key].arn

  runtime_platform {
    cpu_architecture        = each.value.architecture
    operating_system_family = each.value.operating_system_family
  }

  dynamic "ephemeral_storage" {
    for_each = each.value.ephemeral_storage_size == null ? [] : [each.value.ephemeral_storage_size]

    content {
      size_in_gib = ephemeral_storage.value
    }
  }

  container_definitions = jsonencode([
    merge(
      {
        name      = each.value.container_name
        image     = each.value.image
        essential = each.value.essential

        environment = [
          for name in sort(keys(each.value.environment)) : {
            name  = name
            value = each.value.environment[name]
          }
        ]

        secrets = [
          for name in sort(keys(each.value.secrets)) : {
            name      = name
            valueFrom = each.value.secrets[name]
          }
        ]

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.this[each.key].name
            "awslogs-region"        = data.aws_region.current.region
            "awslogs-stream-prefix" = each.value.container_name
          }
        }

        readonlyRootFilesystem = each.value.readonly_root_filesystem
      },
      each.value.command == null ? {} : { command = each.value.command },
      each.value.user == null ? {} : { user = each.value.user },
      each.value.working_directory == null ? {} : { workingDirectory = each.value.working_directory },
      each.value.stop_timeout == null ? {} : { stopTimeout = each.value.stop_timeout },
    )
  ])

  tags = merge(var.tags, each.value.tags)
}
