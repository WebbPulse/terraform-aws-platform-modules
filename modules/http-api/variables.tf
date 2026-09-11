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

variable "integrations" {
  description = <<-EOT
    The Lambda backends behind this API, keyed by a short stable name such as "legacy", "posts" or
    "users". Each entry creates one AWS_PROXY integration and one aws_lambda_permission, both
    addressed by that key, so adding or removing one backend never touches another.

    Per entry:
      lambda_function_name           name of the function, for the resource-based invoke permission
      lambda_invoke_arn              the function's invoke_arn, not its plain arn
      payload_format_version         optional, defaults to var.payload_format_version
      timeout_milliseconds           optional, 50 to 30000; null leaves the service default (30000)
                                     unset, which is what an integration that never set it has in state
      lambda_permission_statement_id optional. The default is var.lambda_permission_statement_id when
                                     this is the only integration or the default_integration, and
                                     "<var.lambda_permission_statement_id>-<key>" otherwise

    The key is a Terraform address. Renaming a key destroys and recreates that integration and its
    permission, so pick names you can live with.
  EOT

  type = map(object({
    lambda_function_name           = string
    lambda_invoke_arn              = string
    payload_format_version         = optional(string)
    timeout_milliseconds           = optional(number)
    lambda_permission_statement_id = optional(string)
  }))

  validation {
    condition     = length(var.integrations) > 0
    error_message = "integrations must name at least one Lambda backend."
  }

  validation {
    condition     = alltrue([for k, _ in var.integrations : can(regex("^[a-zA-Z0-9_-]{1,64}$", k))])
    error_message = "Every integrations key must be 1 to 64 characters of letters, digits, hyphens or underscores; it is a Terraform resource address."
  }

  validation {
    condition = alltrue([
      for k, i in var.integrations :
      can(regex("^arn:aws[a-z-]*:apigateway:[a-z0-9-]+:lambda:path/2015-03-31/functions/arn:aws[a-z-]*:lambda:", i.lambda_invoke_arn))
    ])
    error_message = "Every integrations entry's lambda_invoke_arn must be the function's invoke_arn (arn:aws:apigateway:<region>:lambda:path/2015-03-31/functions/<function arn>/invocations), not its plain arn."
  }

  validation {
    condition     = alltrue([for k, i in var.integrations : length(i.lambda_function_name) > 0])
    error_message = "Every integrations entry needs a non-empty lambda_function_name."
  }

  validation {
    condition = alltrue([
      for k, i in var.integrations :
      i.payload_format_version == null || contains(["1.0", "2.0"], coalesce(i.payload_format_version, "2.0"))
    ])
    error_message = "An integrations entry's payload_format_version must be 1.0 or 2.0."
  }

  validation {
    condition = alltrue([
      for k, i in var.integrations :
      i.timeout_milliseconds == null || (coalesce(i.timeout_milliseconds, 30000) >= 50 && coalesce(i.timeout_milliseconds, 30000) <= 30000)
    ])
    error_message = "An integrations entry's timeout_milliseconds must be between 50 and 30000 when set."
  }

  validation {
    condition = alltrue([
      for k, i in var.integrations :
      i.lambda_permission_statement_id == null || can(regex("^[a-zA-Z0-9-_]+$", coalesce(i.lambda_permission_statement_id, "x")))
    ])
    error_message = "An integrations entry's lambda_permission_statement_id may contain only letters, digits, hyphens and underscores."
  }
}

variable "default_integration" {
  description = <<-EOT
    Key in integrations that serves the $default route: every request no other route claims. During
    a strangler migration this is the monolith, and each prefix moved off it is one more routes
    entry, so the monolith keeps answering everything not yet carved out.

    Set it to null to create no $default route at all, which makes the API answer 404 for anything
    the explicit routes do not match. Only do that once the migration is finished.
  EOT

  type    = string
  default = "legacy"

  validation {
    condition     = var.default_integration == null || can(regex("^[a-zA-Z0-9_-]{1,64}$", var.default_integration))
    error_message = "default_integration must be null or an integrations key."
  }
}

variable "routes" {
  description = <<-EOT
    Explicit routes in front of $default, keyed by route key. The key is the API Gateway route key
    ("ANY /api/v1/posts/{proxy+}", "GET /health") and is also the Terraform address of the route, so
    a route's address is stable as long as its key is.

    Per entry:
      integration        key in integrations that serves this route
      authorization_type optional override, NONE, CUSTOM, AWS_IAM or JWT. Null means the module's
                         own choice: CUSTOM when authorizer_id is set, NONE when it is not. Set it
                         to "NONE" only to deliberately punch a hole in the access gate, for example
                         a health check that has to answer without the gate's cookies
      authorizer_id      optional override, null means var.authorizer_id. Applied only when the
                         effective authorization_type is CUSTOM or JWT; a route that resolves to
                         NONE or AWS_IAM gets no authorizer id, because those types take none and
                         API Gateway stores nothing for them, which would otherwise show as a
                         perpetual in-place authorizer_id update on every later plan
      authorization_scopes optional JWT scopes, only meaningful with a JWT authorizer
      require_identity_jwt optional, false by default. True means this route requires a valid
                         identity access token on top of whatever else protects it, and the module
                         picks the mechanism from the environment it was configured for: with
                         identity_jwt set (production) the route becomes JWT against the identity
                         authorizer, and with identity_jwt null (staging) the route is untouched:
                         the key is published in the identity_jwt_route_keys output and the access
                         gate's Lambda authorizer, which already holds the route's only authorizer
                         slot, verifies the same token on it. An explicit authorization_type on the
                         same entry wins, so a route can still be forced open

    API Gateway picks the most specific match, so an explicit route always wins over $default.

    Note the two keys a resource collection needs. "ANY /api/v1/posts" does not match
    /api/v1/posts/123, and "ANY /api/v1/posts/{proxy+}" does not match the bare collection path.
    Both are needed to carve a prefix off the monolith cleanly.
  EOT

  type = map(object({
    integration          = string
    authorization_type   = optional(string)
    authorizer_id        = optional(string)
    authorization_scopes = optional(list(string))
    require_identity_jwt = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = !contains(keys(var.routes), "$default")
    error_message = "Do not list $default in routes; name the integration that serves it with default_integration instead, so the access gate's authorizer reaches it the same way it reaches every other route."
  }

  validation {
    condition = alltrue([
      for k, _ in var.routes :
      can(regex("^(ANY|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /", k))
    ])
    error_message = "Every routes key must be <METHOD> <path> where METHOD is ANY, GET, POST, PUT, PATCH, DELETE, HEAD or OPTIONS and the path starts with /."
  }

  validation {
    condition = alltrue([
      for k, r in var.routes :
      r.authorization_type == null || contains(["NONE", "CUSTOM", "AWS_IAM", "JWT"], coalesce(r.authorization_type, "NONE"))
    ])
    error_message = "A routes entry's authorization_type must be NONE, CUSTOM, AWS_IAM or JWT."
  }

  # A route that both requires a token and is forced to NONE is a contradiction, and the one that
  # loses silently is the security-relevant half. Saying so at plan time is cheaper than finding out
  # from a request that should have been refused.
  validation {
    condition = alltrue([
      for k, r in var.routes :
      !coalesce(r.require_identity_jwt, false) || coalesce(r.authorization_type, "CUSTOM") != "NONE"
    ])
    error_message = "A routes entry cannot set require_identity_jwt = true together with authorization_type = \"NONE\": NONE takes no authorizer, so the token would not be checked."
  }
}

variable "payload_format_version" {
  description = "Default Lambda proxy payload format version for integrations that do not set their own. 2.0 is the HTTP API native format."
  type        = string
  default     = "2.0"

  validation {
    condition     = contains(["1.0", "2.0"], var.payload_format_version)
    error_message = "payload_format_version must be 1.0 or 2.0."
  }
}

variable "throttling_burst_limit" {
  description = "Default route throttling burst limit on the $default stage: layer 1 of the estate's rate limiting, applied to every route that has no route_settings override."
  type        = number
  default     = 50

  validation {
    condition     = var.throttling_burst_limit >= 0 && floor(var.throttling_burst_limit) == var.throttling_burst_limit
    error_message = "throttling_burst_limit must be a non-negative whole number."
  }
}

variable "throttling_rate_limit" {
  description = "Default route steady-state requests per second on the $default stage, applied to every route that has no route_settings override."
  type        = number
  default     = 25

  validation {
    condition     = var.throttling_rate_limit >= 0
    error_message = "throttling_rate_limit must be non-negative."
  }
}

variable "route_settings" {
  description = <<-EOT
    Per-route stage settings, keyed by route key exactly as routes is, plus "$default" for the
    default route. An entry here overrides the stage's default_route_settings for that one route,
    which is how an expensive path gets a tighter limit than the rest of the API without lowering
    the whole stage.

    Per entry, every field optional:
      throttling_burst_limit   burst for this route only
      throttling_rate_limit    requests per second for this route only
      detailed_metrics_enabled per-route CloudWatch metrics for this route only

    A key that names no route is rejected: API Gateway accepts the setting and then silently
    applies it to nothing.
  EOT

  type = map(object({
    throttling_burst_limit   = optional(number)
    throttling_rate_limit    = optional(number)
    detailed_metrics_enabled = optional(bool)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, s in var.route_settings :
      s.throttling_burst_limit == null || (coalesce(s.throttling_burst_limit, 0) >= 0 && floor(coalesce(s.throttling_burst_limit, 0)) == coalesce(s.throttling_burst_limit, 0))
    ])
    error_message = "A route_settings throttling_burst_limit must be a non-negative whole number."
  }

  validation {
    condition = alltrue([
      for k, s in var.route_settings :
      s.throttling_rate_limit == null || coalesce(s.throttling_rate_limit, 0) >= 0
    ])
    error_message = "A route_settings throttling_rate_limit must be non-negative."
  }
}

variable "detailed_metrics_enabled" {
  description = "Publish per-route CloudWatch metrics from the $default stage. Off by default; each route becomes its own metric dimension when on, which with a per-prefix API is one dimension per prefix."
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
  description = "Default statement_id of the aws_lambda_permission that lets API Gateway invoke a function. Used verbatim when there is only one integration, and otherwise for the default_integration entry, with every other integration getting \"<this>-<key>\". That keeps an adopting consumer's existing permission at the statement id it already has in state, whether or not it names a default_integration. Changing it replaces the permission, a moment with no permission at all."
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
  description = "Id of an aws_apigatewayv2_authorizer on this API, typically staging-access-gate's http_api_authorizer_id. When set, every route the module creates gets authorization_type CUSTOM with this authorizer, $default included, unless that one route overrides it in routes. When null, every route is NONE. A route whose effective authorization_type is NONE or AWS_IAM never carries an authorizer id, since those types take none."
  type        = string
  default     = null
}

variable "cors_configuration" {
  description = <<-EOT
    CORS the API answers preflight with itself, instead of the function doing it. Null, the default,
    creates no cors_configuration block at all, which is what an API that handles CORS in the
    function has in state.

    Setting this makes API Gateway answer OPTIONS for every route without invoking any integration,
    so an application that already sets CORS headers in the function should leave it null rather
    than configure both and have them disagree.
  EOT

  type = object({
    allow_credentials = optional(bool)
    allow_headers     = optional(list(string))
    allow_methods     = optional(list(string))
    allow_origins     = optional(list(string))
    expose_headers    = optional(list(string))
    max_age           = optional(number)
  })
  default = null

  validation {
    condition     = var.cors_configuration == null || !coalesce(try(var.cors_configuration.allow_credentials, false), false) || !contains(coalesce(try(var.cors_configuration.allow_origins, []), []), "*")
    error_message = "cors_configuration cannot set allow_credentials = true together with allow_origins = [\"*\"]; browsers reject that pair and API Gateway will not send the header."
  }
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

# ---------------------------------------------------------------------------
# Identity JWT enforcement
# ---------------------------------------------------------------------------

variable "identity_jwt" {
  description = <<-EOT
    Turn on gateway level enforcement of the identity module's access tokens. Null, the default,
    creates no authorizer and changes nothing, so an existing consumer that does not set it sees no
    plan change at all.

    Fields:
      issuer   the identity issuer, byte for byte the same string the identity module was given.
               API Gateway appends /.well-known/openid-configuration to it and fetches that during
               CreateAuthorizer, so it must be https, must not end in a slash, and must already be
               served when this authorizer is created
      audience the aud claim the identity function stamps. A token whose aud is anything else is
               refused
      name     optional authorizer name, defaults to "<var.name>-identity-jwt"
      audiences        optional, the full list the authorizer accepts when more than one is needed.
                       Null means exactly [audience]
      identity_sources optional, defaults to ["$request.header.Authorization"], which is where a
                       bearer token belongs. API Gateway requires every listed identity source to be
                       present or it answers 401 without evaluating the token
      authorizer_id    optional. An authorizer that already exists on this API, to attach instead of
                       creating one. Pass module.identity.authorizer_id here when the identity
                       module is already making one: its authorizer polls the discovery document
                       before creating itself, which is a stronger ordering guarantee than
                       identity_jwt_depends_on gives, and two authorizers validating the same issuer
                       and audience differ in nothing but their names. issuer and audience are still
                       required, because they are what the validations check the configuration
                       against, but nothing here reads them when this is set

    Set this in PRODUCTION, where a route marked require_identity_jwt gets authorization_type
    "JWT" pointed at this authorizer. Leave it null in STAGING: the route already has to carry the
    access gate's Lambda authorizer and a route takes exactly one authorizer, so there is no slot
    for this one. Enforcement there moves into the gate's Lambda, which is handed the
    identity_jwt_route_keys output as its identity_jwt_route_keys input and verifies the same token
    on the same routes.

    ORDERING. CreateAuthorizer fetches the discovery document synchronously and fails with
    "Issuer must have a valid discovery endpoint" when it does not get one back. The two
    .well-known routes therefore have to exist, answer anonymously, and already be deployed before
    this resource is created. Because this module creates both the routes and the authorizer, the
    graph is routes then authorizer then the protected routes' authorizer attachment, and Terraform
    orders it correctly on its own. What it cannot order is the identity function being deployed
    and warm: see identity_jwt_depends_on.
  EOT

  type = object({
    issuer           = string
    audience         = string
    name             = optional(string)
    audiences        = optional(list(string))
    identity_sources = optional(list(string))
    authorizer_id    = optional(string)
  })
  default = null

  validation {
    condition     = var.identity_jwt == null || startswith(coalesce(try(var.identity_jwt.issuer, null), "https://x"), "https://")
    error_message = "identity_jwt.issuer must be an https URL: API Gateway fetches the discovery document over the public internet and will not accept a plaintext issuer."
  }

  validation {
    condition     = var.identity_jwt == null || !endswith(coalesce(try(var.identity_jwt.issuer, null), "x"), "/")
    error_message = "identity_jwt.issuer must not end with a trailing slash. API Gateway appends /.well-known/openid-configuration to it, and a trailing slash yields a double slash that fetches nothing."
  }

  validation {
    condition     = var.identity_jwt == null || length(coalesce(try(var.identity_jwt.audience, null), "")) > 0
    error_message = "identity_jwt.audience must not be empty: the authorizer matches the token's aud claim against it."
  }

  validation {
    condition     = var.identity_jwt == null || length(coalesce(try(var.identity_jwt.audiences, null), ["x"])) > 0
    error_message = "identity_jwt.audiences must be null or a non-empty list."
  }

  validation {
    condition     = var.identity_jwt == null || length(coalesce(try(var.identity_jwt.identity_sources, null), ["x"])) > 0
    error_message = "identity_jwt.identity_sources must be null or a non-empty list; an empty list makes the authorizer accept a request carrying no token at all."
  }
}

variable "identity_jwt_depends_on" {
  description = <<-EOT
    What must already exist and already answer before the JWT authorizer is created. Pass the
    identity function's module or resource value here.

    This module already orders its own routes before the authorizer, so this is not about the
    routes. It is about the function behind them: UpdateFunctionConfiguration returns while
    LastUpdateStatus is still InProgress, an auto_deploy stage deploys asynchronously, and a
    container image function under the Lambda Web Adapter takes seconds to cold start. Any one of
    them makes CreateAuthorizer fetch a 404, and the failure is the same BadRequestException as
    having no route at all.

    Leave it empty when the identity function is applied in an earlier run.
  EOT

  type    = any
  default = []
}
