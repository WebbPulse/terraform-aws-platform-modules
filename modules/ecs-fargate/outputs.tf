output "cluster_arn" {
  description = "ARN of the ECS cluster. This is the value an ecs:cluster condition names, and the Cluster field of a RunTask call or a Step Functions ecs:runTask parameter block."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster, for a CloudWatch dimension or an aws ecs command's --cluster."
  value       = aws_ecs_cluster.this.name
}

output "task_definition_arns" {
  description = "Revision-qualified ARN of each task definition, keyed the same as the tasks input. This is the exact revision Terraform last created; a RunTask naming it pins that revision, which is usually what a control plane wants."
  value       = local.task_definition_arns
}

output "task_definition_family_arns" {
  description = "Family ARN of each task definition without the revision suffix, keyed the same as the tasks input. A RunTask naming this form takes the latest active revision, and an IAM policy scopes a family with this value plus :*."
  value       = local.task_definition_family_arns
}

output "task_definition_families" {
  description = "Family name of each task definition, keyed the same as the tasks input."
  value       = { for k, t in local.tasks : k => t.family }
}

output "task_definition_revisions" {
  description = "Revision number of each task definition, keyed the same as the tasks input. It increments on every change to a task's definition, so a caller that pins a revision reads it from here."
  value       = { for k, d in aws_ecs_task_definition.this : k => d.revision }
}

output "container_names" {
  description = "Container name inside each task definition, keyed the same as the tasks input. A RunTask containerOverrides block names the container it overrides, so a caller sending a command or an extra environment variable needs this value."
  value       = { for k, t in local.tasks : k => t.container_name }
}

output "log_group_names" {
  description = "Name of each task's CloudWatch log group, keyed the same as the tasks input, for a metric filter or a Logs Insights query."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.name }
}

output "log_group_arns" {
  description = "ARN of each task's CloudWatch log group, keyed the same as the tasks input."
  value       = { for k, g in aws_cloudwatch_log_group.this : k => g.arn }
}

output "execution_role_arn" {
  description = "ARN of the shared task execution role, the role the Fargate agent assumes. A caller's iam:PassRole must cover it, which run_task_policy_json already does."
  value       = aws_iam_role.execution.arn
}

output "execution_role_name" {
  description = "Name of the task execution role, for an aws_iam_role_policy_attachment outside this module."
  value       = aws_iam_role.execution.name
}

output "execution_role_id" {
  description = "Id of the task execution role, which is what an aws_iam_role_policy resource takes as its role argument."
  value       = aws_iam_role.execution.id
}

output "task_role_arns" {
  description = "ARN of each task's own task role, keyed the same as the tasks input. This is the role the container's code runs as, and the one a resource policy elsewhere names as a principal."
  value       = { for k, r in aws_iam_role.task : k => r.arn }
}

output "task_role_names" {
  description = "Name of each task's own task role, keyed the same as the tasks input."
  value       = { for k, r in aws_iam_role.task : k => r.name }
}

output "task_role_ids" {
  description = "Id of each task's own task role, keyed the same as the tasks input, for an aws_iam_role_policy attached outside this module."
  value       = { for k, r in aws_iam_role.task : k => r.id }
}

output "run_task_policy_json" {
  description = "An IAM policy document for a caller that launches these tasks: ecs:RunTask on every family in the map scoped to this cluster, DescribeTasks and StopTask on the cluster, and iam:PassRole on the execution role and every task role with iam:PassedToService fixed to ecs-tasks.amazonaws.com. Attach it with policy = module.<this>.run_task_policy_json. PassRole is the grant most often missed: RunTask alone is denied because the caller is handing two roles to ECS."
  value       = local.run_task_policy_json
}

output "secret_arns" {
  description = "Every distinct secret and parameter ARN named across the task map, so a caller can see what the execution role was granted to read."
  value       = sort(local.secret_arns)
}
