data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = local.execution_role_name
  path                 = var.role_path
  description          = "Task execution role for the ${var.cluster_name} cluster: image pull, secret read and log write for the Fargate agent."
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.role_tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  count = var.attach_execution_role_managed_policy ? 1 : 0

  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution" {
  count = length(local.execution_role_statements) > 0 ? 1 : 0

  name = "task-execution"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.execution_role_statements
  })
}

resource "aws_iam_role" "task" {
  for_each = local.tasks

  name                 = each.value.task_role_name
  path                 = var.role_path
  description          = "Task role for ${each.value.family}: what the container's own code calls."
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.role_tags
}

resource "aws_iam_role_policy" "task" {
  for_each = local.task_keys_with_policies

  name = "task"
  role = aws_iam_role.task[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.task_policy_statements[each.key]
  })
}
