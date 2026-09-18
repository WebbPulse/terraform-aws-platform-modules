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

variable "package_type" {
  description = "How the function's code is packaged, Zip or Image. Zip is the default and takes runtime, handler and a code object naming a local zip or an S3 object. Image takes code.image_uri and must leave runtime and handler null, because the container image supplies both."
  type        = string
  default     = "Zip"

  validation {
    condition     = contains(["Zip", "Image"], var.package_type)
    error_message = "package_type must be Zip or Image."
  }
}

variable "runtime" {
  description = "Lambda managed runtime identifier, for example python3.13 or nodejs22.x. Required when package_type is Zip; must be null when it is Image."
  type        = string
  default     = null

  validation {
    condition     = var.runtime == null || length(coalesce(var.runtime, "x")) > 0
    error_message = "runtime must not be empty; leave it null for an Image function."
  }

  validation {
    condition     = var.package_type == "Image" ? var.runtime == null : var.runtime != null
    error_message = "runtime is required when package_type is Zip and must be null when it is Image, where the container image supplies the runtime."
  }
}

variable "handler" {
  description = "Entry point in the deployment package, for example app.lambda_handler.handler. Required when package_type is Zip; must be null when it is Image, where the image's CMD or the image_config block plays the same role."
  type        = string
  default     = null

  validation {
    condition     = var.handler == null || length(coalesce(var.handler, "x")) > 0
    error_message = "handler must not be empty; leave it null for an Image function."
  }

  validation {
    condition     = var.package_type == "Image" ? var.handler == null : var.handler != null
    error_message = "handler is required when package_type is Zip and must be null when it is Image, where the image's CMD or image_config plays the same role."
  }
}

variable "image_config" {
  description = "Overrides for a container image's own ENTRYPOINT, CMD and WORKDIR, all optional. Null, the default, leaves the block out entirely and the image's own Dockerfile settings stand, which is the right answer for an image that already declares a CMD. Only meaningful when package_type is Image."
  type = object({
    command           = optional(list(string))
    entry_point       = optional(list(string))
    working_directory = optional(string)
  })
  default = null

  validation {
    condition = var.image_config == null || anytrue([
      try(var.image_config.command, null) != null,
      try(var.image_config.entry_point, null) != null,
      try(var.image_config.working_directory, null) != null,
    ])
    error_message = "image_config must set at least one of command, entry_point or working_directory; leave the whole object null to keep the image's own settings."
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

variable "tracing_mode" {
  description = "X-Ray tracing mode, Active or PassThrough. Null leaves the tracing_config block out, which the service reads as PassThrough."
  type        = string
  default     = "Active"

  validation {
    condition     = var.tracing_mode == null || contains(["Active", "PassThrough"], coalesce(var.tracing_mode, "Active"))
    error_message = "tracing_mode must be Active, PassThrough, or null."
  }
}

variable "attach_xray_write_policy" {
  description = "Attach a small inline policy granting xray:PutTraceSegments and xray:PutTelemetryRecords to the execution role whenever tracing_mode is Active. Without it a function with Active tracing emits nothing: the service samples the invoke, the runtime tries to publish the segment, and the call is denied silently, so the traces never appear. Set it to false only when the application already grants those two actions in a policy of its own, which is the case for an estate that carried them in its runtime policy before this module owned them."
  type        = bool
  default     = true
}

variable "environment_variables" {
  description = "Environment variables for the function. An empty map leaves the environment block out entirely, which is not the same as an empty environment block, so pass the variables you want rather than filtering to nothing. otel_environment_variables is merged on top of this map."
  type        = map(string)
  default     = {}
}

variable "otel_environment_variables" {
  description = "OpenTelemetry and Lambda Web Adapter environment variables, merged over environment_variables. It is a separate input purely so an application can keep its own configuration and its tracing configuration apart in the module call; the two maps end up in the same environment block, and a key set in both takes the value from this one. Empty by default, so a consumer that does not set it sees exactly the environment it has today."
  type        = map(string)
  default     = {}
}

variable "code" {
  description = <<-EOT
    Where the deployment package comes from, in one of three shapes. A local zip:
    { filename = data.archive_file.placeholder.output_path, source_code_hash = data.archive_file.placeholder.output_base64sha256 }.
    An object in S3:
    { s3_bucket = aws_s3_bucket.artifacts.id, s3_key = aws_s3_object.placeholder.key, s3_object_version = null, source_code_hash = data.archive_file.placeholder.output_base64sha256 }.
    A container image, which needs package_type = "Image":
    { image_uri = "<account>.dkr.ecr.<region>.amazonaws.com/<repo>@sha256:<digest>" }.
    Set exactly one of filename, s3_bucket and s3_key, or image_uri. This is only the seed package: the code
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

  validation {
    condition     = (var.package_type == "Image") == (var.code.image_uri != null)
    error_message = "code.image_uri and package_type = \"Image\" go together: an Image function needs an image_uri, and a Zip function must not carry one."
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

variable "sqs_event_sources" {
  description = <<-EOT
    SQS queues this function consumes, as a map of a stable key to one queue's wiring. Each entry
    creates an aws_lambda_event_source_mapping from the queue to this function and, unless
    attach_role_policies is off, one inline policy on the execution role granting the three actions
    a poller needs on that queue. Empty, the default, creates neither, so an existing consumer sees
    no plan change.

    The map key names the mapping in state, so it must be stable: renaming a key destroys one
    mapping and creates another, which drops in-flight redrive state for that queue.

    Per entry:
      queue_arn                          required, the queue the mapping polls
      kms_key_arn                        the queue's CMK, when it has one, so the role can decrypt
      batch_size                         records per invocation, 1 to 10000
      maximum_batching_window_seconds    how long to wait to fill a batch, 0 to 300
      function_response_types            ["ReportBatchItemFailures"] by default
      filter_criteria                    list of filter pattern objects, encoded with jsonencode
      maximum_concurrency                scaling_config maximum concurrency, 2 to 1000, null to omit
      enabled                            whether the mapping polls, true by default

    A batch_size above 10 requires maximum_batching_window_seconds to be at least 1, which is the
    service's own rule rather than this module's, and is validated here so the failure lands at plan
    rather than on the CreateEventSourceMapping call.
  EOT

  type = map(object({
    queue_arn                       = string
    kms_key_arn                     = optional(string)
    batch_size                      = optional(number, 10)
    maximum_batching_window_seconds = optional(number, 5)
    function_response_types         = optional(list(string), ["ReportBatchItemFailures"])
    filter_criteria                 = optional(list(any), [])
    maximum_concurrency             = optional(number)
    enabled                         = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for key, source in var.sqs_event_sources :
      can(regex("^arn:aws[a-z-]*:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,80}(\\.fifo)?$", source.queue_arn))
    ])
    error_message = "Every sqs_event_sources entry needs a queue ARN of the form arn:aws:sqs:<region>:<account>:<name>. A queue URL is not an ARN and CreateEventSourceMapping rejects it."
  }

  validation {
    condition = alltrue([
      for key, source in var.sqs_event_sources :
      source.batch_size >= 1 && source.batch_size <= 10000 && floor(source.batch_size) == source.batch_size
    ])
    error_message = "sqs_event_sources batch_size must be a whole number from 1 to 10000."
  }

  validation {
    condition = alltrue([
      for key, source in var.sqs_event_sources :
      source.maximum_batching_window_seconds >= 0 && source.maximum_batching_window_seconds <= 300 && floor(source.maximum_batching_window_seconds) == source.maximum_batching_window_seconds
    ])
    error_message = "sqs_event_sources maximum_batching_window_seconds must be a whole number from 0 to 300."
  }

  validation {
    condition = alltrue([
      for key, source in var.sqs_event_sources :
      source.batch_size <= 10 || source.maximum_batching_window_seconds >= 1
    ])
    error_message = "An sqs_event_sources entry with batch_size above 10 must set maximum_batching_window_seconds to at least 1. Lambda rejects a larger batch with no batching window, because without a window it has nothing to wait on to fill one."
  }

  validation {
    condition = alltrue([
      for key, source in var.sqs_event_sources :
      source.maximum_concurrency == null || (
        coalesce(source.maximum_concurrency, 2) >= 2 &&
        coalesce(source.maximum_concurrency, 2) <= 1000 &&
        floor(coalesce(source.maximum_concurrency, 2)) == coalesce(source.maximum_concurrency, 2)
      )
    ])
    error_message = "sqs_event_sources maximum_concurrency must be a whole number from 2 to 1000, or null to leave the scaling_config block out."
  }

  validation {
    condition = alltrue([
      for key, source in var.sqs_event_sources :
      source.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", coalesce(source.kms_key_arn, "")))
    ])
    error_message = "sqs_event_sources kms_key_arn must be a KMS key ARN. An alias ARN does not work in a kms:Decrypt resource, because the key policy is evaluated against the key."
  }

  validation {
    condition = alltrue([
      for key, source in var.sqs_event_sources :
      length(source.function_response_types) == 0 || alltrue([
        for response_type in source.function_response_types :
        response_type == "ReportBatchItemFailures"
      ])
    ])
    error_message = "ReportBatchItemFailures is the only function response type SQS accepts; leave the list empty to opt out of partial batch responses entirely."
  }
}

variable "dynamodb_stream_event_sources" {
  description = <<-EOT
    DynamoDB table streams this function consumes, as a map of a stable key to one stream's wiring.
    Each entry creates an aws_lambda_event_source_mapping from the stream to this function and,
    unless attach_role_policies is off, one inline policy on the execution role granting the four
    actions a stream reader needs on that stream, plus a send or publish grant on the on failure
    destination when one is given. Empty, the default, creates neither, so an existing consumer sees
    no plan change.

    The map key names the mapping in state, so it must be stable: renaming a key destroys one
    mapping and creates another, and the new mapping starts from starting_position rather than from
    where the old one left off.

    Per entry:
      stream_arn                         required, the table stream the mapping reads
      batch_size                         records per invocation, 1 to 10000
      starting_position                  LATEST or TRIM_HORIZON
      maximum_batching_window_in_seconds how long to wait to fill a batch, 0 to 300
      filter_patterns                    list of JSON filter strings, for example INSERT and MODIFY only
      bisect_batch_on_function_error     split a failing batch in two and retry each half
      maximum_retry_attempts             retries of a failing record, 0 to 10000, -1 for unlimited
      on_failure_destination_arn         SQS queue or SNS topic a discarded batch's metadata goes to
      enabled                            whether the mapping reads, true by default

    A stream ARN carries the table's stream label, so it ends in /stream/<timestamp> rather than
    naming the table alone. A table ARN in its place is rejected here, because
    CreateEventSourceMapping would reject it on the create call instead.
  EOT

  type = map(object({
    stream_arn                         = string
    batch_size                         = optional(number, 100)
    starting_position                  = optional(string, "LATEST")
    maximum_batching_window_in_seconds = optional(number, 0)
    filter_patterns                    = optional(list(string), [])
    bisect_batch_on_function_error     = optional(bool, true)
    maximum_retry_attempts             = optional(number)
    on_failure_destination_arn         = optional(string)
    enabled                            = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for key, source in var.dynamodb_stream_event_sources :
      can(regex("^arn:aws[a-z-]*:dynamodb:[a-z0-9-]+:[0-9]{12}:table/[A-Za-z0-9_.-]+/stream/.+$", source.stream_arn))
    ])
    error_message = "Every dynamodb_stream_event_sources entry needs a stream ARN of the form arn:aws:dynamodb:<region>:<account>:table/<name>/stream/<label>. A table ARN is not a stream ARN, and the table's stream_arn is null until stream_view_type is set on the table."
  }

  validation {
    condition = alltrue([
      for key, source in var.dynamodb_stream_event_sources :
      source.batch_size >= 1 && source.batch_size <= 10000 && floor(source.batch_size) == source.batch_size
    ])
    error_message = "dynamodb_stream_event_sources batch_size must be a whole number from 1 to 10000."
  }

  validation {
    condition = alltrue([
      for key, source in var.dynamodb_stream_event_sources :
      contains(["LATEST", "TRIM_HORIZON"], source.starting_position)
    ])
    error_message = "dynamodb_stream_event_sources starting_position must be LATEST or TRIM_HORIZON. AT_TIMESTAMP is a Kinesis position and a DynamoDB stream does not accept it."
  }

  validation {
    condition = alltrue([
      for key, source in var.dynamodb_stream_event_sources :
      source.maximum_batching_window_in_seconds >= 0 && source.maximum_batching_window_in_seconds <= 300 && floor(source.maximum_batching_window_in_seconds) == source.maximum_batching_window_in_seconds
    ])
    error_message = "dynamodb_stream_event_sources maximum_batching_window_in_seconds must be a whole number from 0 to 300."
  }

  validation {
    condition = alltrue([
      for key, source in var.dynamodb_stream_event_sources :
      alltrue([for pattern in source.filter_patterns : can(jsondecode(pattern))])
    ])
    error_message = "Every dynamodb_stream_event_sources filter_patterns entry must be a JSON string, for example jsonencode({ eventName = [\"INSERT\", \"MODIFY\"] }). The mapping takes the pattern already encoded."
  }

  validation {
    condition = alltrue([
      for key, source in var.dynamodb_stream_event_sources :
      source.maximum_retry_attempts == null || (
        coalesce(source.maximum_retry_attempts, 0) >= -1 &&
        coalesce(source.maximum_retry_attempts, 0) <= 10000 &&
        floor(coalesce(source.maximum_retry_attempts, 0)) == coalesce(source.maximum_retry_attempts, 0)
      )
    ])
    error_message = "dynamodb_stream_event_sources maximum_retry_attempts must be a whole number from 0 to 10000, or -1 for the service default of retrying until the record expires, or null to leave the argument unset."
  }

  validation {
    condition = alltrue([
      for key, source in var.dynamodb_stream_event_sources :
      source.on_failure_destination_arn == null || can(regex("^arn:aws[a-z-]*:(sqs|sns):[a-z0-9-]+:[0-9]{12}:.+$", coalesce(source.on_failure_destination_arn, "")))
    ])
    error_message = "dynamodb_stream_event_sources on_failure_destination_arn must be an SQS queue ARN or an SNS topic ARN. Those are the only two destinations a stream event source mapping accepts for a discarded batch."
  }
}

variable "attach_role_policies" {
  description = <<-EOT
    Attach the inline source read policies the sqs_event_sources and dynamodb_stream_event_sources
    entries need to the execution role. True, the default, is the ordinary case: the role is created
    here, so its name is known and the grant can be ordered ahead of the mapping.

    It cannot be false while either map is non-empty. CreateEventSourceMapping checks the function
    role can read the source during the create call, and the mapping is created by this module, so it
    can only be ordered behind a grant this module also creates. Attach the
    sqs_event_source_policy_json or dynamodb_stream_event_source_policy_json outputs by hand and
    build the mappings yourself if the grants have to live elsewhere.
  EOT

  type    = bool
  default = true

  validation {
    condition     = var.attach_role_policies || length(var.sqs_event_sources) == 0
    error_message = "attach_role_policies is false but sqs_event_sources is not empty. CreateEventSourceMapping checks the function role can read the queue during the create call, and the mapping is created by this module, so it can only be ordered behind a grant this module also creates. Leave attach_role_policies true on the apply that wires a queue, or pass no sqs_event_sources and build the mappings yourself from the sqs_event_source_policy_json output."
  }

  validation {
    condition     = var.attach_role_policies || length(var.dynamodb_stream_event_sources) == 0
    error_message = "attach_role_policies is false but dynamodb_stream_event_sources is not empty. CreateEventSourceMapping checks the function role can read the stream during the create call, and the mapping is created by this module, so it can only be ordered behind a grant this module also creates. Leave attach_role_policies true on the apply that wires a stream, or pass no dynamodb_stream_event_sources and build the mappings yourself from the dynamodb_stream_event_source_policy_json output."
  }
}

variable "events_path" {
  description = <<-EOT
    Path the Lambda Web Adapter posts a non-HTTP invocation to, which the FastAPI application mounts
    its event route on. Reaches the function as both AWS_LWA_PASS_THROUGH_PATH, read by the adapter,
    and APP_EVENTS_PATH, read by the application, so the two cannot drift apart.

    Emitted only when sqs_event_sources or dynamodb_stream_event_sources is non-empty. Turning pass
    through on without a package that mounts the route makes the adapter post a batch to a path that
    404s, and the mapping then retries the batch until the queue's redrive policy gives up on it or
    the stream record expires.
  EOT

  type    = string
  default = "/events"

  validation {
    condition     = startswith(var.events_path, "/")
    error_message = "events_path must start with a slash: the adapter posts to it as an absolute path."
  }
}
