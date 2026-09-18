variable "name" {
  description = "Name of the state machine. It is the name as-is, not a prefix, for example webbpulse-terraform-production-run. Changing it replaces the state machine and every execution history attached to it."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,80}$", var.name))
    error_message = "name must be 1 to 80 characters of letters, digits, hyphens and underscores. Step Functions accepts a wider set, but a name outside it cannot appear in a log group name or a CloudWatch dimension without escaping."
  }
}

variable "definition" {
  description = "The Amazon States Language definition as a JSON string, for example jsonencode({ ... }) or file(\"$${path.module}/run.asl.json\"). Placeholders of the form $${key} are replaced from definition_substitutions before the string reaches the service, so a definition file can name a resource it cannot know the ARN of. The module validates the substituted result rather than this string, so a placeholder may stand where a number or an array belongs."
  type        = string
}

variable "definition_substitutions" {
  description = <<-EOT
    Values for the $${key} placeholders in definition, for example
    { TaskDefinitionArn = module.tasks.task_definition_arns["plan"] }. Every key is optional from
    the module's point of view: a placeholder with no entry here reaches the service literally and
    fails the service's own validation at apply.

    A placeholder is substituted by templatestring, so it stands for a fragment of the JSON text
    rather than for a JSON string value. A placeholder written unquoted, "Seconds": $${Timeout} or
    "Subnets": $${SubnetIdsJson}, takes a number or an array; pass tostring(...) or
    jsonencode(...) for those. The module validates the definition after substitution, so such a
    definition plans as long as the substituted result is valid JSON.
  EOT
  type        = map(string)
  default     = {}
}

variable "type" {
  description = "State machine type, STANDARD or EXPRESS. STANDARD is the default and the only type with a durable execution history, exactly-once semantics and task-token callbacks; EXPRESS is at-least-once, caps out at five minutes and cannot use .sync or waitForTaskToken."
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXPRESS"], var.type)
    error_message = "type must be STANDARD or EXPRESS."
  }
}

variable "role_name" {
  description = "Name of the IAM execution role created for the state machine. Leave null for the state machine name with a -role suffix."
  type        = string
  default     = null

  validation {
    condition     = var.role_name == null || can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be 1 to 64 characters of letters, digits and the characters + = , . @ _ -."
  }
}

variable "role_path" {
  description = "IAM path of the execution role. Changing it replaces the role."
  type        = string
  default     = "/"

  validation {
    condition     = startswith(var.role_path, "/") && endswith(var.role_path, "/")
    error_message = "role_path must start and end with a slash, for example / or /service/."
  }
}

variable "role_description" {
  description = "Description shown on the IAM execution role. Leave null for none."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Optional ARN of a permissions boundary policy to set on the execution role."
  type        = string
  default     = null
}

variable "role_tags" {
  description = "Extra tags on the IAM execution role only, on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}

variable "policy_statements" {
  description = "Statements of the execution role's inline policy, one object per IAM statement: everything the definition's states actually call. Give either actions or not_actions, and either resources or not_resources; effect defaults to Allow, sid and condition are optional. condition is operator -> key -> values. The module adds the logging statement itself, so this list carries only the work: ecs:RunTask, lambda:InvokeFunction, states:StartExecution and so on. An empty list creates no work policy, which is a state machine that can log and nothing else."
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
    condition     = alltrue([for s in var.policy_statements : contains(["Allow", "Deny"], s.effect)])
    error_message = "Every statement's effect must be Allow or Deny."
  }

  validation {
    condition     = alltrue([for s in var.policy_statements : length(coalesce(s.actions, [])) > 0 != (length(coalesce(s.not_actions, [])) > 0)])
    error_message = "Every statement needs exactly one of actions or not_actions, with at least one entry. IAM rejects a statement that carries both Action and NotAction."
  }

  validation {
    condition     = alltrue([for s in var.policy_statements : length(coalesce(s.resources, [])) > 0 != (length(coalesce(s.not_resources, [])) > 0)])
    error_message = "Every statement needs exactly one of resources or not_resources, with at least one entry. Use \"*\" as the resource for actions that do not support resource-level permissions."
  }

  validation {
    condition     = alltrue([for s in var.policy_statements : s.condition == null || alltrue([for op, kv in coalesce(s.condition, {}) : length(kv) > 0 && alltrue([for k, v in kv : length(v) > 0])])])
    error_message = "Every condition operator needs at least one key, and every key at least one value."
  }

  validation {
    condition     = length(distinct(compact([for s in var.policy_statements : s.sid == null ? "" : s.sid]))) == length(compact([for s in var.policy_statements : s.sid == null ? "" : s.sid]))
    error_message = "Statement sids must be unique within the policy. Statements without a sid are ignored by this check; IAM only requires sids to be unique among the statements that have one."
  }
}

variable "policy_name" {
  description = "Name of the single inline policy on the execution role that carries policy_statements."
  type        = string
  default     = "work"
}

variable "log_group_name" {
  description = "Name of the CloudWatch log group created for the state machine. Leave null for /aws/vendedlogs/states/<name>, which is the prefix Step Functions' own console uses and the one a vended-logs delivery is cheapest under."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of the state machine's log group in days. 0 means never expire."
  type        = number
  default     = 14

  validation {
    condition = contains([
      0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096,
      1827, 2192, 2557, 2922, 3288, 3653,
    ], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
}

variable "log_group_kms_key_id" {
  description = "ARN of a KMS key to encrypt the log group with. Null uses the CloudWatch Logs service key."
  type        = string
  default     = null
}

variable "log_group_tags" {
  description = "Extra tags on the CloudWatch log group only, on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}

variable "log_level" {
  description = "Which execution history events reach the log group: ALL, ERROR, FATAL or OFF. ALL is the default because an execution history is the only record of a run's steps and it expires after 90 days, while the log group's retention is yours to set. OFF leaves the logging_configuration in place with nothing flowing, which is cheaper and blind."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ALL", "ERROR", "FATAL", "OFF"], var.log_level)
    error_message = "log_level must be ALL, ERROR, FATAL or OFF."
  }
}

variable "include_execution_data" {
  description = "Include each state's input and output payloads in the logged events. On by default, because without it a failed run logs that a state failed but not what it was given. Turn it off for a machine whose payloads carry anything you would not put in a log group, since the payloads are logged verbatim and CloudWatch Logs has no redaction."
  type        = bool
  default     = true
}

variable "tracing_enabled" {
  description = "Enable X-Ray tracing for executions. Off by default: a trace per execution costs per segment and a state machine orchestrating already-traced work adds little. Turning it on also needs the X-Ray write grant, which attach_xray_write_policy handles."
  type        = bool
  default     = false
}

variable "attach_xray_write_policy" {
  description = "Attach an inline policy granting the five X-Ray actions Step Functions calls whenever tracing_enabled is true. Without it a traced state machine emits nothing: the service tries to publish the segment, the call is denied, and the trace is simply absent with no error on the execution. Set it to false only when the role's permissions are granted from outside."
  type        = bool
  default     = true
}

variable "publish" {
  description = "Publish a numbered version on every definition or configuration change, which is what a state machine alias points at. Off by default; a control plane that always runs the current definition has no use for a version."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags on the state machine only, on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}
