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

run "container_insights_is_off_by_default" {
  command = plan

  assert {
    condition     = one([for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"]) == "disabled"
    error_message = "Container Insights must default to disabled. It bills per observed metric, and a cluster running only short on-demand tasks produces a metric bill out of all proportion to what it reports; the task's own log group is the record that matters."
  }
}

run "container_insights_can_be_turned_up_when_asked" {
  command = plan

  variables {
    container_insights = "enhanced"
  }

  assert {
    condition     = one([for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"]) == "enhanced"
    error_message = "An explicit container_insights value must reach the cluster, so a consumer that has decided the per-task metrics are worth paying for gets them."
  }
}

run "an_insights_value_ecs_does_not_offer_is_rejected" {
  command = plan

  variables {
    container_insights = "on"
  }

  expect_failures = [var.container_insights]
}

run "the_task_runs_on_fargate_arm64_with_awsvpc_networking" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.this["plan"].requires_compatibilities == toset(["FARGATE"])
    error_message = "The task definition must require FARGATE. This module creates no capacity provider and no container instances, so a definition that also allowed EC2 would be launchable in a way nothing here supports."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].network_mode == "awsvpc"
    error_message = "network_mode must be awsvpc: it is the only mode Fargate supports, and it is what gives the task its own ENI, which is what makes a public subnet with a public IP work without a NAT gateway."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].runtime_platform[0].cpu_architecture == "ARM64"
    error_message = "architecture must default to ARM64. Fargate Graviton is cheaper per vCPU-hour, and the default being arm64 is a decision the image has to match: an amd64-only image fails at startup with an exec format error rather than at apply."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].runtime_platform[0].operating_system_family == "LINUX"
    error_message = "operating_system_family must default to LINUX, which is the only family an arm64 Fargate task runs on."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].family == "example-staging-plan"
    error_message = "With family left null the task family must be <cluster_name>-<key>, because the key is the only short name a consumer gave and the family has to be stable: changing it starts a new revision series and orphans the old one."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].cpu == "512" && aws_ecs_task_definition.this["plan"].memory == "1024"
    error_message = "cpu and memory must reach the task definition as given; Fargate only accepts certain pairs and silently substituting either one would produce a task sized differently from what the consumer asked for."
  }

  assert {
    condition     = length(aws_ecs_task_definition.this["plan"].ephemeral_storage) == 0
    error_message = "With ephemeral_storage_size null the block must be left out entirely, which takes the Fargate default of 20 GiB; writing a block with a null size is rejected by the API."
  }
}

run "an_amd64_task_can_ask_for_x86" {
  command = plan

  variables {
    tasks = {
      plan = {
        image        = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
        cpu          = "512"
        memory       = "1024"
        architecture = "X86_64"
      }
    }
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].runtime_platform[0].cpu_architecture == "X86_64"
    error_message = "A task whose image is only built for amd64 must be able to say so, otherwise the arm64 default leaves it failing at startup with an exec format error."
  }
}

run "the_container_definition_carries_the_image_environment_and_log_configuration" {
  command = plan

  variables {
    tasks = {
      plan = {
        image   = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
        cpu     = "512"
        memory  = "1024"
        command = ["terraform", "plan"]

        environment = {
          TF_IN_AUTOMATION = "true"
          RUN_MODE         = "plan"
        }
      }
    }
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].name == "plan"
    error_message = "With container_name left null the container must be named after the task key, because a RunTask containerOverrides block names the container it overrides and the key is the name a consumer already knows."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].image == "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
    error_message = "The image must reach the container definition verbatim; it is the one field that decides what actually runs."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].command == ["terraform", "plan"]
    error_message = "command must reach the container definition in order, because an argument list reordered is a different command."
  }

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].environment) == 2
    error_message = "Every environment entry must reach the container definition; a dropped variable surfaces as a runtime configuration error inside the container rather than at apply."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].environment[0].name == "RUN_MODE"
    error_message = "The environment list must be sorted by name. A map has no order of its own, so rendering it unsorted makes the container definition JSON churn between plans and shows a diff on a task nothing changed about."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].logConfiguration.logDriver == "awslogs"
    error_message = "The log driver must be awslogs, which is what delivers the container's stdout to the log group this module creates; without it the output goes nowhere and a failed task leaves no record."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].logConfiguration.options["awslogs-group"] == "/aws/ecs/example-staging/plan"
    error_message = "The awslogs group must be the group the module created for this task, not an invented name: a driver pointing at a group nothing manages leaves the retention unenforced and the logs unfindable."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].logConfiguration.options["awslogs-region"] == "us-west-2"
    error_message = "The awslogs driver needs an explicit region; without it the agent cannot resolve the endpoint and the task fails at startup rather than merely logging nothing."
  }

  assert {
    condition     = !can(jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].user)
    error_message = "An unset user must be left out of the container definition rather than rendered as null, because a null there is a diff against the definition ECS normalizes and stores."
  }
}

run "each_task_gets_its_own_log_group_with_its_own_retention" {
  command = plan

  variables {
    tasks = {
      plan = {
        image              = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
        cpu                = "512"
        memory             = "1024"
        log_retention_days = 7
      }
      apply = {
        image              = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
        cpu                = "1024"
        memory             = "2048"
        log_retention_days = 30
      }
    }
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 2
    error_message = "Every task must get a log group of its own, so one task's output cannot be mistaken for another's and each can carry its own retention."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["plan"].retention_in_days == 7 && aws_cloudwatch_log_group.this["apply"].retention_in_days == 30
    error_message = "Each task's log_retention_days must reach its own group; a shared retention would force the shortest or longest choice on every task in the map."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["apply"].name == "/aws/ecs/example-staging/apply"
    error_message = "With no prefix given each group must be /aws/ecs/<cluster_name>/<key>, which keeps every task in the cluster under one searchable prefix."
  }

  assert {
    condition     = length(aws_ecs_task_definition.this) == 2
    error_message = "Every entry in the tasks map must produce a task definition; the map is the whole interface for adding a task."
  }
}

run "the_default_retention_is_a_value_cloudwatch_accepts" {
  command = plan

  assert {
    condition = contains([
      0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096,
      1827, 2192, 2557, 2922, 3288, 3653,
    ], aws_cloudwatch_log_group.this["plan"].retention_in_days)
    error_message = "Whatever the default retention is, it must be a value CloudWatch Logs accepts; the service rejects anything else at apply, so a bad default would break every consumer that never sets it."
  }
}

run "explicit_names_and_ephemeral_storage_reach_the_task" {
  command = plan

  variables {
    log_group_name_prefix = "/example/staging/tasks"

    tasks = {
      plan = {
        image                    = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example@sha256:aaaa"
        cpu                      = "512"
        memory                   = "1024"
        family                   = "example-staging-terraform-plan"
        container_name           = "runner"
        ephemeral_storage_size   = 50
        readonly_root_filesystem = true
        user                     = "1000:1000"
        working_directory        = "/workspace"
        stop_timeout             = 30
      }
    }
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].family == "example-staging-terraform-plan"
    error_message = "An explicit family must replace the derived default outright, because a consumer adopting a family that already has revisions in ECS needs the module to land on exactly that name."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this["plan"].name == "/example/staging/tasks/plan"
    error_message = "log_group_name_prefix must drive the group name, so an estate with its own log naming scheme is not forced onto the /aws/ecs default."
  }

  assert {
    condition     = aws_ecs_task_definition.this["plan"].ephemeral_storage[0].size_in_gib == 50
    error_message = "ephemeral_storage_size must reach the task; a Terraform runner cloning a large repository fills the 20 GiB default and fails mid-run with no disk space, which is not obviously a storage problem from the logs."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].name == "runner"
    error_message = "An explicit container_name must win over the key, because a containerOverrides block in an existing caller already names the container."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].user == "1000:1000"
    error_message = "user must reach the container definition, which is how a task runs as something other than root."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].workingDirectory == "/workspace"
    error_message = "working_directory must be rendered as workingDirectory: the container definition uses camelCase keys, and a snake_case key is silently ignored by ECS rather than rejected."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this["plan"].container_definitions)[0].readonlyRootFilesystem
    error_message = "readonly_root_filesystem must be rendered as readonlyRootFilesystem, again in the camelCase the API expects."
  }
}

run "an_empty_task_map_is_rejected" {
  command = plan

  variables {
    tasks = {}
  }

  expect_failures = [var.tasks]
}

run "a_cpu_fargate_does_not_offer_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image  = "example@sha256:aaaa"
        cpu    = "300"
        memory = "1024"
      }
    }
  }

  expect_failures = [var.tasks]
}

run "an_ephemeral_storage_below_the_api_minimum_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image                  = "example@sha256:aaaa"
        cpu                    = "512"
        memory                 = "1024"
        ephemeral_storage_size = 20
      }
    }
  }

  expect_failures = [var.tasks]
}

run "an_architecture_fargate_does_not_offer_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image        = "example@sha256:aaaa"
        cpu          = "512"
        memory       = "1024"
        architecture = "arm64"
      }
    }
  }

  expect_failures = [var.tasks]
}

run "a_retention_cloudwatch_does_not_accept_is_rejected" {
  command = plan

  variables {
    tasks = {
      plan = {
        image              = "example@sha256:aaaa"
        cpu                = "512"
        memory             = "1024"
        log_retention_days = 10
      }
    }
  }

  expect_failures = [var.tasks]
}
