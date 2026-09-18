variable "cluster_name" {
  description = "Name of the ECS cluster. It is the name as-is, not a prefix, for example webbpulse-terraform-production. Changing it replaces the cluster."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,255}$", var.cluster_name))
    error_message = "cluster_name must be 1 to 255 characters of letters, digits, hyphens and underscores."
  }
}

variable "container_insights" {
  description = "Container Insights setting for the cluster: disabled, enhanced or enabled. Disabled by default and deliberately: Insights bills per observed metric and a cluster that only runs short on-demand tasks produces a metric bill out of proportion to what it tells you. The task's own log group is the record that matters."
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights must be disabled, enabled or enhanced. enabled is the original per-cluster metrics; enhanced is the newer per-task set and costs more."
  }
}

variable "cluster_tags" {
  description = "Extra tags on the ECS cluster only, on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}

variable "tasks" {
  description = <<-EOT
    The task definitions to create, one entry per task, keyed by a short name such as "plan" or
    "apply". The key names the family as "<cluster_name>-<key>" unless family overrides it, and
    names the task's log group and task role the same way.

    Each entry sets cpu and memory as strings from the Fargate pairs ECS accepts ("512"/"1024"),
    the container image, and optionally command, environment, secrets, task_policy_statements,
    ephemeral_storage_size, architecture, operating_system_family, log_retention_days,
    log_group_kms_key_id, container_name, essential, readonly_root_filesystem, user, working_directory,
    stop_timeout and tags.

    secrets maps an environment variable name to a Secrets Manager secret ARN or an SSM parameter
    ARN. The module derives the execution role's read grant from the ARNs given, so a secret added
    here is readable without touching a policy by hand. A Secrets Manager ARN may name a JSON key
    with the "<arn>:<json-key>:<version-stage>:<version-id>" form ECS understands.

    task_policy_statements is the task role's inline policy: what the container's own code calls,
    which is separate from what the agent needs to start the task.
  EOT

  type = map(object({
    image   = string
    cpu     = string
    memory  = string
    command = optional(list(string))

    family         = optional(string)
    container_name = optional(string)

    environment = optional(map(string), {})
    secrets     = optional(map(string), {})

    architecture            = optional(string, "ARM64")
    operating_system_family = optional(string, "LINUX")

    essential                = optional(bool, true)
    readonly_root_filesystem = optional(bool, false)
    user                     = optional(string)
    working_directory        = optional(string)
    stop_timeout             = optional(number)

    ephemeral_storage_size = optional(number)

    log_group_name       = optional(string)
    log_retention_days   = optional(number, 14)
    log_group_kms_key_id = optional(string)

    task_policy_statements = optional(list(object({
      sid           = optional(string)
      effect        = optional(string, "Allow")
      actions       = optional(list(string))
      not_actions   = optional(list(string))
      resources     = optional(list(string))
      not_resources = optional(list(string))
      condition     = optional(map(map(list(string))))
    })), [])

    tags = optional(map(string), {})
  }))

  validation {
    condition     = length(var.tasks) > 0
    error_message = "tasks must hold at least one entry; a cluster with no task definition is a cluster nothing can run."
  }

  validation {
    condition     = alltrue([for k, t in var.tasks : can(regex("^[A-Za-z0-9_-]{1,200}$", k))])
    error_message = "Every tasks key must be 1 to 200 characters of letters, digits, hyphens and underscores, because the key is used to build the family, log group and role names."
  }

  validation {
    condition     = alltrue([for k, t in var.tasks : contains(["ARM64", "X86_64"], t.architecture)])
    error_message = "Every task's architecture must be ARM64 or X86_64. ARM64 is the default: Fargate Graviton is cheaper per vCPU-hour, and it requires an image built for arm64."
  }

  validation {
    condition     = alltrue([for k, t in var.tasks : contains(["LINUX", "WINDOWS_SERVER_2019_CORE", "WINDOWS_SERVER_2022_CORE"], t.operating_system_family)])
    error_message = "Every task's operating_system_family must be LINUX or one of the Windows Server core families ECS offers."
  }

  validation {
    condition     = alltrue([for k, t in var.tasks : can(tonumber(t.cpu)) && can(tonumber(t.memory))])
    error_message = "Every task's cpu and memory must be numeric strings, for example cpu = \"512\" and memory = \"1024\". They are strings rather than numbers because that is the shape the ECS API takes."
  }

  validation {
    condition     = alltrue([for k, t in var.tasks : contains([256, 512, 1024, 2048, 4096, 8192, 16384], tonumber(t.cpu))])
    error_message = "Every task's cpu must be one of the Fargate values: 256, 512, 1024, 2048, 4096, 8192 or 16384. Fargate rejects anything else, and only some cpu and memory pairs are legal together."
  }

  validation {
    condition     = alltrue([for k, t in var.tasks : tonumber(t.memory) >= 512 && tonumber(t.memory) % 1024 == 0 || tonumber(t.memory) == 512])
    error_message = "Every task's memory must be 512 or a whole multiple of 1024 MiB. Fargate ties the legal memory range to the cpu value, so check the pair against the Fargate table as well."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      t.ephemeral_storage_size == null || (coalesce(t.ephemeral_storage_size, 21) >= 21 && coalesce(t.ephemeral_storage_size, 21) <= 200)
    ])
    error_message = "Every task's ephemeral_storage_size must be between 21 and 200 GiB, or null to take the Fargate default of 20 GiB. 21 is the smallest value the API accepts, because 20 is the implicit default rather than a settable size."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks : contains([
        0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096,
        1827, 2192, 2557, 2922, 3288, 3653,
      ], t.log_retention_days)
    ])
    error_message = "Every task's log_retention_days must be one of the values CloudWatch Logs accepts: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }

  validation {
    condition = alltrue(flatten([
      for k, t in var.tasks : [for s in t.task_policy_statements : contains(["Allow", "Deny"], s.effect)]
    ]))
    error_message = "Every task_policy_statements effect must be Allow or Deny."
  }

  validation {
    condition = alltrue(flatten([
      for k, t in var.tasks : [
        for s in t.task_policy_statements :
        length(coalesce(s.actions, [])) > 0 != (length(coalesce(s.not_actions, [])) > 0)
      ]
    ]))
    error_message = "Every task_policy_statements entry needs exactly one of actions or not_actions, with at least one entry. IAM rejects a statement carrying both Action and NotAction."
  }

  validation {
    condition = alltrue(flatten([
      for k, t in var.tasks : [
        for s in t.task_policy_statements :
        length(coalesce(s.resources, [])) > 0 != (length(coalesce(s.not_resources, [])) > 0)
      ]
    ]))
    error_message = "Every task_policy_statements entry needs exactly one of resources or not_resources, with at least one entry. Use \"*\" for actions that do not support resource-level permissions."
  }

  validation {
    condition = alltrue(flatten([
      for k, t in var.tasks : [
        for s in t.task_policy_statements :
        s.condition == null || alltrue([for op, kv in coalesce(s.condition, {}) : length(kv) > 0 && alltrue([for key, v in kv : length(v) > 0])])
      ]
    ]))
    error_message = "Every task_policy_statements condition operator needs at least one key, and every key at least one value."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      length(distinct(compact([for s in t.task_policy_statements : s.sid == null ? "" : s.sid]))) == length(compact([for s in t.task_policy_statements : s.sid == null ? "" : s.sid]))
    ])
    error_message = "Statement sids must be unique within a task's policy. Statements without a sid are ignored by this check; IAM only requires sids to be unique among the statements that have one."
  }

  validation {
    condition = alltrue(flatten([
      for k, t in var.tasks : [
        for name, arn in t.secrets :
        can(regex("^arn:[a-z0-9-]+:(secretsmanager|ssm):", arn))
      ]
    ]))
    error_message = "Every secrets value must be a Secrets Manager secret ARN or an SSM parameter ARN. ECS resolves the value itself from the ARN; a plain secret name or a raw value does not work here, and a raw value belongs in environment instead."
  }

  validation {
    condition = alltrue(flatten([
      for k, t in var.tasks : [
        for name, arn in t.secrets :
        can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name))
      ]
    ]))
    error_message = "Every secrets key is an environment variable name, so it must start with a letter or underscore and hold only letters, digits and underscores."
  }

  validation {
    condition = alltrue([
      for k, t in var.tasks :
      length(setintersection(keys(t.environment), keys(t.secrets))) == 0
    ])
    error_message = "A task may not name the same variable in both environment and secrets. ECS rejects the task definition rather than picking a winner."
  }
}

variable "execution_role_name" {
  description = "Name of the shared task execution role, the role the Fargate agent itself assumes to pull the image, read the secrets and write the logs. Leave null for <cluster_name>-task-execution. One role serves every task in the map, because the agent's job is the same for all of them."
  type        = string
  default     = null

  validation {
    condition     = var.execution_role_name == null || can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.execution_role_name))
    error_message = "execution_role_name must be 1 to 64 characters of letters, digits and the characters + = , . @ _ -."
  }
}

variable "task_role_name_prefix" {
  description = "Prefix for each task's own task role, which is named \"<prefix>-<task key>\". Leave null for the cluster name, giving <cluster_name>-<key>. Each task gets its own role so one task's grants are not reachable by another's container."
  type        = string
  default     = null

  validation {
    condition     = var.task_role_name_prefix == null || can(regex("^[A-Za-z0-9+=,.@_-]{1,48}$", var.task_role_name_prefix))
    error_message = "task_role_name_prefix must be 1 to 48 characters of letters, digits and the characters + = , . @ _ -, leaving room for the task key suffix."
  }
}

variable "role_path" {
  description = "IAM path of the execution role and every task role. Changing it replaces the roles."
  type        = string
  default     = "/"

  validation {
    condition     = startswith(var.role_path, "/") && endswith(var.role_path, "/")
    error_message = "role_path must start and end with a slash, for example / or /service/."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional ARN of a permissions boundary policy to set on the execution role and every task role."
  type        = string
  default     = null
}

variable "attach_execution_role_managed_policy" {
  description = "Attach the AWS managed AmazonECSTaskExecutionRolePolicy to the execution role. On by default: it carries the ECR pull and CloudWatch Logs write the Fargate agent needs, and without it a task fails at startup with a CannotPullContainerError before any code runs. The module adds the secret read grants separately, because the managed policy does not cover them."
  type        = bool
  default     = true
}

variable "execution_role_policy_statements" {
  description = "Extra statements for the execution role's inline policy, on top of the secret read grants the module derives from the task map. For a case the derived grants do not cover, such as a KMS key decrypt on a customer-managed key encrypting a secret, or an ECR pull through a cross-account repository policy. Shaped like a task's task_policy_statements."
  type = list(object({
    sid           = optional(string)
    effect        = optional(string, "Allow")
    actions       = optional(list(string))
    not_actions   = optional(list(string))
    resources     = optional(list(string))
    not_resources = optional(list(string))
    condition     = optional(map(map(list(string))))
  }))
  default = []

  validation {
    condition     = alltrue([for s in var.execution_role_policy_statements : contains(["Allow", "Deny"], s.effect)])
    error_message = "Every statement's effect must be Allow or Deny."
  }

  validation {
    condition     = alltrue([for s in var.execution_role_policy_statements : length(coalesce(s.actions, [])) > 0 != (length(coalesce(s.not_actions, [])) > 0)])
    error_message = "Every statement needs exactly one of actions or not_actions, with at least one entry."
  }

  validation {
    condition     = alltrue([for s in var.execution_role_policy_statements : length(coalesce(s.resources, [])) > 0 != (length(coalesce(s.not_resources, [])) > 0)])
    error_message = "Every statement needs exactly one of resources or not_resources, with at least one entry."
  }
}

variable "log_group_name_prefix" {
  description = "Prefix for each task's CloudWatch log group, which is named \"<prefix>/<task key>\". Leave null for /aws/ecs/<cluster_name>. A task's own log_group_name overrides both."
  type        = string
  default     = null
}

variable "role_tags" {
  description = "Extra tags on the execution role and every task role, on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}

variable "log_group_tags" {
  description = "Extra tags on every task log group, on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Extra tags on every task definition, on top of the provider's default_tags and each task's own tags."
  type        = map(string)
  default     = {}
}
