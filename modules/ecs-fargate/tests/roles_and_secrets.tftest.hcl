variables {
  cluster_name = "example-staging"

  tasks = {
    plan = {
      image  = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
      cpu    = "512"
      memory = "1024"
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

run "the_two_roles_are_separate_and_both_trusted_to_ecs_tasks" {
  command = plan

  override_resource {
    target          = aws_iam_role.execution
    override_during = plan
    values = {
      arn = "arn:aws:iam::123456789012:role/example-staging-task-execution"
    }
  }

  override_resource {
    target          = aws_iam_role.task
    override_during = plan
    values = {
      arn = "arn:aws:iam::123456789012:role/example-staging-plan"
    }
  }

  assert {
    condition     = aws_iam_role.execution.name == "example-staging-task-execution"
    error_message = "With execution_role_name left null the execution role must be <cluster_name>-task-execution; it is shared across every task because the Fargate agent's job is the same for all of them."
  }

  assert {
    condition     = aws_iam_role.task["plan"].name == "example-staging-plan"
    error_message = "Each task must get its own task role named <prefix>-<key>, so one task's grants are not reachable from another task's container."
  }

  assert {
    condition     = aws_iam_role.execution.arn != aws_iam_role.task["plan"].arn
    error_message = "The execution role and the task role must be different roles. This is the split the module exists to get right: the execution role is the agent pulling the image and reading the secrets before the container starts, the task role is the container's own code. Collapsing them hands the application everything the agent can do, including reading every secret the task references."
  }

  assert {
    condition     = jsondecode(aws_iam_role.execution.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
    error_message = "Both roles must be assumable by ecs-tasks.amazonaws.com and nothing else; ecs.amazonaws.com is the service-linked principal for the scheduler and does not work for either of these."
  }

  assert {
    condition     = jsondecode(aws_iam_role.task["plan"].assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
    error_message = "The task role's trust policy must name ecs-tasks.amazonaws.com; a task role that trusts the wrong principal fails the RunTask call with an assume-role error that does not name the trust policy."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].execution_role_arn == aws_iam_role.execution.arn
    error_message = "The task definition's execution_role_arn must be the module's execution role, or the agent has no identity to pull the image with."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].task_role_arn == aws_iam_role.task["plan"].arn
    error_message = "The task definition's task_role_arn must be this task's own role; pointing every task at one role is the collapse this module avoids."
  }
}

run "the_managed_execution_policy_is_attached_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy_attachment.execution_managed) == 1
    error_message = "AmazonECSTaskExecutionRolePolicy must be attached by default: it carries the ECR pull and the CloudWatch Logs write the agent needs, and without it the task dies at startup with a CannotPullContainerError before any code runs."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.execution_managed[0].policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    error_message = "The managed policy ARN must be built from the partition data source so the module works outside the commercial partition, where the aws: prefix differs."
  }

  assert {
    condition     = length(aws_iam_role_policy.execution) == 0
    error_message = "With no secrets and no extra statements the execution role must carry no inline policy at all; an empty policy resource is noise a consumer has to reason about."
  }
}

run "the_managed_policy_can_be_left_off" {
  command = plan

  variables {
    attach_execution_role_managed_policy = false
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.execution_managed) == 0
    error_message = "attach_execution_role_managed_policy false must attach nothing, for an estate that grants the agent's permissions through a policy of its own."
  }
}

run "the_secret_read_grant_is_derived_from_the_task_map" {
  command = plan

  variables {
    tasks = {
      plan = {
        image  = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
        cpu    = "512"
        memory = "1024"

        secrets = {
          TFE_TOKEN   = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf:tfe_token::"
          DB_PASSWORD = "arn:aws:ssm:us-west-2:123456789012:parameter/example/db"
        }
      }
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.execution) == 1
    error_message = "A task naming secrets must produce an inline execution policy; deriving the grant from the ARNs given is the whole point, so a consumer never has to write the read policy by hand."
  }

  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Sid], "ReadTaskSecrets")
    error_message = "A Secrets Manager ARN must produce a secretsmanager:GetSecretValue statement; without it the task fails at startup with a ResourceInitializationError naming the secret, which reads as a missing secret rather than a missing permission."
  }

  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Sid], "ReadTaskParameters")
    error_message = "An SSM parameter ARN must produce an ssm:GetParameters statement. The two ARN shapes need different actions, so a module granting only one of them breaks the other silently."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Resource if s.Sid == "ReadTaskSecrets"]) == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf"
    error_message = "The Secrets Manager resource must be the bare secret ARN with the json-key, version-stage and version-id suffixes stripped. IAM matches against the secret ARN, so a policy naming the ARN with :tfe_token:: still attached matches nothing and the read is denied."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Resource if s.Sid == "ReadTaskParameters"]) == "arn:aws:ssm:us-west-2:123456789012:parameter/example/db"
    error_message = "An SSM parameter ARN must be used as given; unlike a Secrets Manager ARN it carries no random suffix and no key selector to strip."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].secrets[0].name == "DB_PASSWORD"
    error_message = "The secrets list must be sorted by name for the same reason the environment list is: a map has no order, and an unsorted render churns the container definition JSON between plans."
  }

  assert {
    condition     = one([for s in jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].secrets : s.valueFrom if s.name == "TFE_TOKEN"]) == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf:tfe_token::"
    error_message = "The container's valueFrom must keep the full ARN including the json-key selector, because that is what tells ECS which key of the JSON blob to inject. Only the IAM resource is truncated, not the reference."
  }

  assert {
    condition     = length(output.secret_arns) == 2
    error_message = "The secret_arns output must report every distinct ARN the task map named, so a consumer can see what the execution role was granted to read."
  }
}

run "one_secret_shared_by_two_tasks_is_granted_once" {
  command = plan

  variables {
    tasks = {
      plan = {
        image  = "example@sha256:aaaa"
        cpu    = "512"
        memory = "1024"
        secrets = {
          TOKEN = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf:token::"
        }
      }
      apply = {
        image  = "example@sha256:aaaa"
        cpu    = "512"
        memory = "1024"
        secrets = {
          TOKEN = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf:other::"
        }
      }
    }
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Resource if s.Sid == "ReadTaskSecrets"]) == "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf"
    error_message = "Two tasks naming two keys of the same secret must collapse to a single resource entry rather than the same ARN twice, because the truncated ARNs are identical and a duplicated resource is a policy diff on every plan."
  }
}

run "an_extra_execution_statement_joins_the_derived_grants" {
  command = plan

  variables {
    tasks = {
      plan = {
        image  = "example@sha256:aaaa"
        cpu    = "512"
        memory = "1024"
        secrets = {
          TOKEN = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf:token::"
        }
      }
    }

    execution_role_policy_statements = [
      {
        sid       = "DecryptSecretKey"
        actions   = ["kms:Decrypt"]
        resources = ["arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"]
      },
    ]
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.execution[0].policy).Statement) == 2
    error_message = "An extra execution statement must be appended to the derived grants rather than replacing them, or adding a KMS decrypt would silently drop the secret read it exists to complete."
  }

  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Action if s.Sid == "DecryptSecretKey"]) == "kms:Decrypt"
    error_message = "A single-element actions list must render as a bare JSON string, matching how a hand-written policy is spelled. A secret encrypted with a customer-managed key needs this grant, and without it the read is denied even though the secret policy allows it."
  }
}

run "the_task_role_carries_only_what_the_caller_asked_for" {
  command = plan

  variables {
    tasks = {
      plan = {
        image  = "example@sha256:aaaa"
        cpu    = "512"
        memory = "1024"

        task_policy_statements = [
          {
            sid       = "ReadState"
            actions   = ["s3:GetObject", "s3:PutObject"]
            resources = ["arn:aws:s3:::example-staging-state/*"]
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

  assert {
    condition     = length(aws_iam_role_policy.task) == 1
    error_message = "Only a task that supplied statements may get an inline task policy; a task with none must produce no policy resource, so its container starts with no AWS permissions of its own at all."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.task["plan"].policy).Statement[0].Action == ["s3:GetObject", "s3:PutObject"]
    error_message = "A multi-element actions list must render as a JSON list in the caller's order; a reordered document is a diff on every plan even though the grant is unchanged."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.task["plan"].policy).Statement[0].Resource == "arn:aws:s3:::example-staging-state/*"
    error_message = "The caller's resource must reach the task policy verbatim, since it is the only thing scoping the container's own access."
  }
}

run "a_task_naming_a_variable_in_both_environment_and_secrets_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image       = "example@sha256:aaaa"
        cpu         = "512"
        memory      = "1024"
        environment = { TOKEN = "plain" }
        secrets     = { TOKEN = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-AbCdEf" }
      }
    }
  }

  expect_failures = [var.tasks]
}

run "a_secret_that_is_not_an_arn_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image   = "example@sha256:aaaa"
        cpu     = "512"
        memory  = "1024"
        secrets = { TOKEN = "example/app" }
      }
    }
  }

  expect_failures = [var.tasks]
}

run "a_secret_key_that_is_not_a_variable_name_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image   = "example@sha256:aaaa"
        cpu     = "512"
        memory  = "1024"
        secrets = { "TF-TOKEN" = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example-AbCdEf" }
      }
    }
  }

  expect_failures = [var.tasks]
}

run "a_task_statement_with_both_actions_and_not_actions_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image  = "example@sha256:aaaa"
        cpu    = "512"
        memory = "1024"
        task_policy_statements = [
          {
            actions     = ["s3:GetObject"]
            not_actions = ["s3:PutObject"]
            resources   = ["*"]
          },
        ]
      }
    }
  }

  expect_failures = [var.tasks]
}
