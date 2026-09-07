variable "name" {
  description = "Name of the HTTP API, for example carmodpicker-production-api. Also the default basis for the access log group name, /aws/apigateway/<name>."
  type        = string

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 128
    error_message = "name must be between 1 and 128 characters."
  }
}

variable "description" {
  description = "Description shown on the API in the console. Leave null for none; an API that has no description today must keep null to plan clean."
  type        = string
  default     = null
}

variable "lambda_invoke_arn" {
  description = "invoke_arn of the Lambda function the API proxies to (aws_lambda_function.<name>.invoke_arn). The function itself is owned by the consumer."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:apigateway:[a-z0-9-]+:lambda:path/2015-03-31/functions/arn:aws[a-z-]*:lambda:", var.lambda_invoke_arn))
    error_message = "lambda_invoke_arn must be the function's invoke_arn (arn:aws:apigateway:<region>:lambda:path/2015-03-31/functions/<function arn>/invocations), not its plain arn."
  }
}

variable "lambda_function_name" {
  description = "Name of that Lambda function, used for the resource-based invoke permission."
  type        = string

  validation {
    condition     = length(var.lambda_function_name) > 0
    error_message = "lambda_function_name must not be empty."
  }
}

variable "route_keys" {
  description = "Route keys that target the Lambda integration, one route per entry. Each is also the for_each key of its aws_apigatewayv2_route, so the address of a route is stable as long as its key is. Either [\"$default\"] (everything to the function) or explicit keys such as [\"ANY /{proxy+}\", \"ANY /\"]."
  type        = list(string)
  default     = ["$default"]

  validation {
    condition     = length(var.route_keys) > 0
    error_message = "route_keys must list at least one route key, otherwise the API answers nothing."
  }

  validation {
    condition     = length(distinct(var.route_keys)) == length(var.route_keys)
    error_message = "route_keys contains a duplicate; each key can exist once on an API."
  }

  validation {
    condition     = alltrue([for k in var.route_keys : k == "$default" || can(regex("^(ANY|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /", k))])
    error_message = "Every route key must be $default or <METHOD> <path> where METHOD is ANY, GET, POST, PUT, PATCH, DELETE, HEAD or OPTIONS and the path starts with /."
  }
}

variable "payload_format_version" {
  description = "Lambda proxy payload format version the integration sends the function. 2.0 is the HTTP API native format."
  type        = string
  default     = "2.0"

  validation {
    condition     = contains(["1.0", "2.0"], var.payload_format_version)
    error_message = "payload_format_version must be 1.0 or 2.0."
  }
}

variable "integration_timeout_milliseconds" {
  description = "Integration timeout in milliseconds, 50 to 30000. Null leaves the API Gateway default (30000) in place without writing it into the configuration, which is what an integration that never set a timeout has in state."
  type        = number
  default     = null

  validation {
    condition     = var.integration_timeout_milliseconds == null || (var.integration_timeout_milliseconds >= 50 && var.integration_timeout_milliseconds <= 30000)
    error_message = "integration_timeout_milliseconds must be between 50 and 30000 when set."
  }
}

variable "throttling_burst_limit" {
  description = "Default route throttling burst limit on the $default stage."
  type        = number
  default     = 50

  validation {
    condition     = var.throttling_burst_limit >= 0 && floor(var.throttling_burst_limit) == var.throttling_burst_limit
    error_message = "throttling_burst_limit must be a non-negative whole number."
  }
}

variable "throttling_rate_limit" {
  description = "Default route steady-state requests per second on the $default stage."
  type        = number
  default     = 25

  validation {
    condition     = var.throttling_rate_limit >= 0
    error_message = "throttling_rate_limit must be non-negative."
  }
}

variable "detailed_metrics_enabled" {
  description = "Publish per-route CloudWatch metrics from the $default stage. Off by default; each route becomes its own metric dimension when on."
  type        = bool
  default     = false
}

variable "access_log_group_name" {
  description = "CloudWatch Logs group that receives the stage access log. Null means /aws/apigateway/<name>."
  type        = string
  default     = null
}

variable "access_log_retention_days" {
  description = "Retention of the access log group in days. Must be a value CloudWatch Logs accepts; 0 keeps logs forever."
  type        = number
  default     = 14

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.access_log_retention_days)
    error_message = "access_log_retention_days must be one of the retention periods CloudWatch Logs supports (0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "access_log_format" {
  description = "Fields of the JSON access log line, field name to $context variable. The stage stores jsonencode() of this map, keys sorted, so two consumers with the same set of fields have byte-identical formats regardless of how they order them."
  type        = map(string)
  default = {
    requestId               = "$context.requestId"
    requestTime             = "$context.requestTime"
    ip                      = "$context.identity.sourceIp"
    userAgent               = "$context.identity.userAgent"
    httpMethod              = "$context.httpMethod"
    path                    = "$context.path"
    routeKey                = "$context.routeKey"
    protocol                = "$context.protocol"
    status                  = "$context.status"
    responseLength          = "$context.responseLength"
    responseLatency         = "$context.responseLatency"
    integrationLatency      = "$context.integrationLatency"
    integrationStatus       = "$context.integrationStatus"
    integrationErrorMessage = "$context.integrationErrorMessage"
  }

  validation {
    condition     = length(var.access_log_format) > 0
    error_message = "access_log_format must have at least one field; API Gateway rejects an empty access log format."
  }

  validation {
    condition     = alltrue([for k, v in var.access_log_format : startswith(v, "$context.")])
    error_message = "Every access_log_format value must be a $context.* variable."
  }
}

variable "lambda_permission_statement_id" {
  description = "statement_id of the aws_lambda_permission that lets API Gateway invoke the function. Changing it replaces the permission (a moment with no permission at all), so an adopting consumer passes whatever its existing permission uses."
  type        = string
  default     = "AllowHttpApiInvoke"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-_]+$", var.lambda_permission_statement_id))
    error_message = "lambda_permission_statement_id may contain only letters, digits, hyphens and underscores."
  }
}

variable "disable_execute_api_endpoint" {
  description = "Turn off the default https://<api-id>.execute-api.<region>.amazonaws.com endpoint so the API is reachable only through its custom domain. Pair with authorizer_id when the staging access gate fronts the API."
  type        = bool
  default     = false

  validation {
    condition     = !var.disable_execute_api_endpoint || var.domain_name != null
    error_message = "disable_execute_api_endpoint = true without a domain_name leaves the API with no hostname at all."
  }
}

variable "authorizer_id" {
  description = "Id of an aws_apigatewayv2_authorizer on this API, typically staging-access-gate's http_api_authorizer_id. When set, every route gets authorization_type CUSTOM with this authorizer; when null, every route is open (NONE)."
  type        = string
  default     = null
}

variable "domain_name" {
  description = "Custom hostname for the API, for example api.example.com. Null creates no custom domain, mapping or DNS record; the API is then served from its execute-api endpoint."
  type        = string
  default     = null

  validation {
    condition     = var.domain_name == null || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lowercase fully qualified hostname such as api.example.com."
  }
}

variable "certificate_arn" {
  description = "ARN of an issued ACM certificate in this region covering domain_name. Required when domain_name is set. Pass aws_acm_certificate_validation.<name>.certificate_arn rather than the certificate's own arn so the domain waits for validation; the certificate and its validation records stay with the consumer, see the README."
  type        = string
  default     = null

  validation {
    condition     = var.domain_name == null || var.certificate_arn != null
    error_message = "certificate_arn is required when domain_name is set: an API Gateway custom domain cannot exist without a certificate."
  }

  validation {
    condition     = var.certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN (arn:aws:acm:<region>:<account>:certificate/<id>)."
  }
}

variable "zone_id" {
  description = "Route 53 hosted zone that domain_name lives in. When set, the module writes an alias A record for domain_name using the module's aws provider, so the zone must be in the same account and reachable with the same credentials as the API. Leave null and write the record yourself when the zone is elsewhere or written through a provider alias."
  type        = string
  default     = null

  validation {
    condition     = var.zone_id == null || var.domain_name != null
    error_message = "zone_id has no effect without a domain_name; remove one or set the other."
  }
}

variable "domain_name_tags" {
  description = "Tags applied only to the custom domain resource, merged over tags. Exists so an adopting consumer can keep a Name tag its domain already carries."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to every taggable resource this module creates (API, stage, log group, custom domain). Provider default_tags still apply on top; leave empty to rely on them alone."
  type        = map(string)
  default     = {}
}
