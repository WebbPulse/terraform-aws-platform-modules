variable "function_name" {
  description = "Name of the Lambda function. It is the name as-is, not a prefix, for example carmodpicker-production-api. Changing it replaces the function."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,64}$", var.function_name))
    error_message = "function_name must be 1 to 64 characters of letters, digits, hyphens and underscores."
  }
}

variable "role_name" {
  description = "Name of the IAM execution role created for the function. Leave null for the function name with a -role suffix. The application attaches its own permissions to this role with aws_iam_role_policy or aws_iam_role_policy_attachment resources of its own, using the role_name or role_id output."
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
  description = "Description shown on the IAM execution role. Leave null for none, which is what both applications have in state today."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Optional ARN of a permissions boundary policy to set on the execution role."
  type        = string
  default     = null
}

variable "assume_role_service_principals" {
  description = "Service principals allowed to assume the execution role. lambda.amazonaws.com is the function itself; add edgelambda.amazonaws.com for a Lambda@Edge function."
  type        = list(string)
  default     = ["lambda.amazonaws.com"]

  validation {
    condition     = length(var.assume_role_service_principals) > 0
    error_message = "assume_role_service_principals must list at least one principal; an empty list is a role the function cannot assume."
  }

  validation {
    condition     = length(distinct(var.assume_role_service_principals)) == length(var.assume_role_service_principals)
    error_message = "assume_role_service_principals contains a duplicate entry."
  }
}

variable "role_tags" {
  description = "Extra tags on the IAM execution role only, on top of the provider's default_tags."
  type        = map(string)
  default     = {}
}

variable "runtime" {
  description = "Lambda managed runtime identifier, for example python3.13 or nodejs22.x."
  type        = string

  validation {
    condition     = length(var.runtime) > 0
    error_message = "runtime must not be empty."
  }
}

variable "handler" {
  description = "Entry point in the deployment package, for example app.lambda_handler.handler."
  type        = string

  validation {
    condition     = length(var.handler) > 0
    error_message = "handler must not be empty."
  }
}

variable "architectures" {
  description = "Instruction set the function runs on, exactly one of [\"x86_64\"] or [\"arm64\"]. Changing it forces the deployment package to match."
  type        = list(string)
  default     = ["x86_64"]

  validation {
    condition     = length(var.architectures) == 1 && contains(["x86_64", "arm64"], var.architectures[0])
    error_message = "architectures must be exactly one of [\"x86_64\"] or [\"arm64\"]."
  }
}

variable "memory_size" {
  description = "Memory in MB, which also sets the CPU share. Lambda accepts 128 to 10240."
  type        = number
  default     = 128

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 MB."
  }
}

variable "timeout" {
  description = "Maximum run time in seconds, 1 to 900. Behind an API Gateway HTTP API keep it at or below 29, the integration's own ceiling."
  type        = number
  default     = 3

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "description" {
  description = "Description shown on the function. Leave null for none, which is what both applications have in state today."
  type        = string
  default     = null
}

variable "publish" {
  description = "Publish a numbered version on every code or configuration change. Both applications deploy code out of band and leave this off."
  type        = bool
  default     = false
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrency for the function. Leave null, or -1, for no reservation."
  type        = number
  default     = null

  validation {
    condition     = var.reserved_concurrent_executions == null || var.reserved_concurrent_executions >= -1
    error_message = "reserved_concurrent_executions must be -1 or greater, or null for no reservation."
  }
}

variable "environment_variables" {
  description = "Environment variables for the function. An empty map leaves the environment block out entirely, which is not the same as an empty environment block, so pass the variables you want rather than filtering to nothing."
  type        = map(string)
  default     = {}
}

variable "tracing_mode" {
  description = "X-Ray tracing mode, Active or PassThrough. Null leaves the tracing_config block out, which the service reads as PassThrough."
  type        = string
  default     = "Active"

  validation {
    condition     = var.tracing_mode == null || contains(["Active", "PassThrough"], coalesce(var.tracing_mode, "Active"))
    error_message = "tracing_mode must be Active, PassThrough, or null."
  }
}

variable "code" {
  description = <<-EOT
    Where the deployment package comes from, in one of two shapes. A local zip:
    { filename = data.archive_file.placeholder.output_path, source_code_hash = data.archive_file.placeholder.output_base64sha256 }.
    An object in S3:
    { s3_bucket = aws_s3_bucket.artifacts.id, s3_key = aws_s3_object.placeholder.key, s3_object_version = null, source_code_hash = data.archive_file.placeholder.output_base64sha256 }.
    Set filename or s3_bucket and s3_key, never both. This is only the seed package: the code
    attributes named in ignore_code_changes are ignored afterwards, so a deployment pipeline that
    calls UpdateFunctionCode is not undone by the next plan. The archive_file or S3 object that
    produces the seed stays with the application, because one builds it from a directory in the
    repository and the other from inline content.
  EOT

  type = object({
    filename          = optional(string)
    s3_bucket         = optional(string)
    s3_key            = optional(string)
    s3_object_version = optional(string)
    source_code_hash  = optional(string)
    image_uri         = optional(string)
  })

  validation {
    condition = length(compact([
      var.code.filename,
      var.code.s3_bucket,
      var.code.image_uri,
    ])) == 1
    error_message = "code must set exactly one of filename, s3_bucket or image_uri."
  }

  validation {
    condition     = (var.code.s3_bucket == null) == (var.code.s3_key == null)
    error_message = "code.s3_bucket and code.s3_key must be set together."
  }
}

variable "layers" {
  description = "ARNs of Lambda layers to attach, in order. Empty for none."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.layers) <= 5
    error_message = "Lambda accepts at most 5 layers on a function."
  }
}

variable "log_group_name" {
  description = "Name of the CloudWatch log group created for the function. Leave null for /aws/lambda/<function_name>, which is the group Lambda writes to by default."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of the function's log group in days. 0 means never expire."
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

variable "log_format" {
  description = "Format Lambda writes its own platform logs in, JSON or Text. JSON is what makes application_log_level and system_log_level available."
  type        = string
  default     = "JSON"

  validation {
    condition     = contains(["JSON", "Text"], var.log_format)
    error_message = "log_format must be JSON or Text."
  }
}

variable "application_log_level" {
  description = "Minimum level of application log Lambda forwards. Only meaningful with log_format JSON; leave null with Text, which is the shape one of the two applications has in state."
  type        = string
  default     = null

  validation {
    condition     = var.application_log_level == null || contains(["TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"], coalesce(var.application_log_level, "INFO"))
    error_message = "application_log_level must be one of TRACE, DEBUG, INFO, WARN, ERROR, FATAL, or null."
  }
}

variable "system_log_level" {
  description = "Minimum level of Lambda's own platform log Lambda forwards. Only meaningful with log_format JSON."
  type        = string
  default     = null

  validation {
    condition     = var.system_log_level == null || contains(["DEBUG", "INFO", "WARN"], coalesce(var.system_log_level, "INFO"))
    error_message = "system_log_level must be one of DEBUG, INFO, WARN, or null."
  }
}

variable "set_logging_config_log_group" {
  description = "Name the log group explicitly in the function's logging_config. Both values point at the same group; which one is in state is a historical difference between the two applications, and flipping it is an in place update of the function, so match what the application has rather than picking a side."
  type        = bool
  default     = false
}

variable "vpc_config" {
  description = "Run the function in a VPC. Null, the default, leaves it outside one. Attaching a function to a VPC requires the execution role to carry AWSLambdaVPCAccessExecutionRole or equivalent network permissions, which the application attaches itself."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null

  validation {
    condition     = var.vpc_config == null || length(coalesce(try(var.vpc_config.subnet_ids, null), [])) > 0
    error_message = "vpc_config.subnet_ids must list at least one subnet."
  }

  validation {
    condition     = var.vpc_config == null || length(coalesce(try(var.vpc_config.security_group_ids, null), [])) > 0
    error_message = "vpc_config.security_group_ids must list at least one security group."
  }
}

variable "ephemeral_storage_size" {
  description = "Size of /tmp in MB, 512 to 10240. Null leaves the block out, which is 512."
  type        = number
  default     = null

  validation {
    condition     = var.ephemeral_storage_size == null || (coalesce(var.ephemeral_storage_size, 512) >= 512 && coalesce(var.ephemeral_storage_size, 512) <= 10240)
    error_message = "ephemeral_storage_size must be between 512 and 10240 MB, or null."
  }
}

variable "tags" {
  description = "Extra tags on the Lambda function only, on top of the provider's default_tags. Leave empty to rely on default_tags alone, which is what one of the two applications does today."
  type        = map(string)
  default     = {}
}
