variables {
  cluster_name = "example-staging"

  tasks = {
    plan = {
      image  = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
      cpu    = "512"
      memory = "1024"
    }
    apply = {
      image  = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
      cpu    = "1024"
      memory = "2048"
    }
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

override_data {
  target = data.aws_region.current
  values = {
    region = "us-west-2"
  }
}

override_resource {
  target          = aws_ecs_cluster.this
  override_during = plan
  values = {
    arn = "arn:aws:ecs:us-west-2:123456789012:cluster/example-staging"
  }
}

override_resource {
  target          = aws_iam_role.execution
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/example-staging-task-execution"
  }
}

override_resource {
  target          = aws_iam_role.task["plan"]
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/example-staging-plan"
  }
}

override_resource {
  target          = aws_iam_role.task["apply"]
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:role/example-staging-apply"
  }
}

run "run_task_is_scoped_to_the_families_and_the_cluster" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Action if s.Sid == "RunTask"]) == "ecs:RunTask"
    error_message = "The policy must grant ecs:RunTask, which is the action a Step Functions ecs:runTask state or a RunTask API call needs."
  }

  assert {
    condition = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Resource if s.Sid == "RunTask"]) == [
      "arn:aws:ecs:us-west-2:123456789012:task-definition/example-staging-apply:*",
      "arn:aws:ecs:us-west-2:123456789012:task-definition/example-staging-plan:*",
    ]
    error_message = "RunTask must be scoped to each family ARN with a :* revision wildcard, sorted so the document does not churn. The revision wildcard matters: a policy naming a single revision denies the call the moment the task definition is updated, which looks like an unrelated regression on the next deploy."
  }

  assert {
    condition     = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Condition.ArnEquals["ecs:cluster"] if s.Sid == "RunTask"]) == "arn:aws:ecs:us-west-2:123456789012:cluster/example-staging"
    error_message = "RunTask must carry an ecs:cluster condition pinning this cluster. Without it the grant lets the holder run those families on any cluster in the account, including one with a different network configuration."
  }
}

run "pass_role_covers_both_roles_and_is_pinned_to_the_ecs_tasks_service" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Action if s.Sid == "PassTaskRoles"]) == "iam:PassRole"
    error_message = "The policy must grant iam:PassRole. This is the grant most often missed: RunTask alone is denied, because the caller is handing ECS two roles and IAM treats that as passing them."
  }

  assert {
    condition     = contains(one([for s in jsondecode(output.run_task_policy_json).Statement : s.Resource if s.Sid == "PassTaskRoles"]), "arn:aws:iam::123456789012:role/example-staging-task-execution")
    error_message = "PassRole must cover the execution role; a RunTask passing an execution role the caller cannot pass is denied before the task is ever scheduled."
  }

  assert {
    condition     = length(one([for s in jsondecode(output.run_task_policy_json).Statement : s.Resource if s.Sid == "PassTaskRoles"])) == 3
    error_message = "PassRole must cover the execution role and every task role, and no more: both an execution role and a task role are passed on every RunTask, and a wildcard there would let the holder pass any role in the account to ECS. Two tasks plus the shared execution role is three entries."
  }

  assert {
    condition     = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Condition.StringEquals["iam:PassedToService"] if s.Sid == "PassTaskRoles"]) == "ecs-tasks.amazonaws.com"
    error_message = "PassRole must be pinned to ecs-tasks.amazonaws.com with iam:PassedToService, which is what stops the grant being used to hand these roles to some other service."
  }
}

run "describe_and_stop_are_granted_on_the_cluster" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Action if s.Sid == "DescribeAndStopTask"]) == ["ecs:DescribeTasks", "ecs:StopTask"]
    error_message = "DescribeTasks and StopTask must be granted: a .sync integration polls DescribeTasks to learn the task finished, and Step Functions calls StopTask when the execution is aborted or the state times out."
  }

  assert {
    condition     = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Resource if s.Sid == "DescribeAndStopTask"]) == "*"
    error_message = "DescribeTasks and StopTask take a task ARN, which does not exist until the task is running and so cannot be named in a policy; the ecs:cluster condition is what bounds them instead."
  }

  assert {
    condition     = one([for s in jsondecode(output.run_task_policy_json).Statement : s.Condition.ArnEquals["ecs:cluster"] if s.Sid == "DescribeAndStopTask"]) == "arn:aws:ecs:us-west-2:123456789012:cluster/example-staging"
    error_message = "The cluster condition must bound DescribeTasks and StopTask too, or the wildcard resource would let the holder stop any task in the account."
  }
}

run "the_family_arn_outputs_are_the_two_shapes_a_caller_needs" {
  command = plan

  assert {
    condition     = output.task_definition_family_arns["plan"] == "arn:aws:ecs:us-west-2:123456789012:task-definition/example-staging-plan"
    error_message = "The family ARN must carry no revision suffix: a RunTask naming this form takes the latest active revision, which is what a caller that should not pin a revision wants."
  }

  assert {
    condition     = output.task_definition_families["apply"] == "example-staging-apply"
    error_message = "The families output must give the bare family name, which is what an aws ecs run-task --task-definition takes when a revision is not being pinned."
  }

  assert {
    condition     = output.container_names["plan"] == "plan"
    error_message = "The container_names output exists so a caller building a containerOverrides block never has to hard-code the container name; a wrong name there makes ECS reject the override rather than ignore it."
  }
}
