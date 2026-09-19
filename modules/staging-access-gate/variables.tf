variable "name" {
  description = "Prefix for every resource this module creates, for example carmodpicker-staging. Lowercase letters, digits and hyphens only; it is also used as the Cognito hosted UI domain prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.name))
    error_message = "name must be 2 to 41 characters of lowercase letters, digits and hyphens."
  }

  validation {
    condition     = !strcontains(var.name, "aws") && !strcontains(var.name, "cognito")
    error_message = "name must not contain the words aws or cognito: Cognito rejects hosted UI domain prefixes that do."
  }
}

variable "cookie_domain" {
  description = "Registrable parent of every hostname the gate protects, for example staging.carmodpicker.com. The signed cookies are scoped to this domain and the signed policy covers https://*<cookie_domain>/*, so it must be the apex of the staging site, not the www host."
  type        = string

  validation {
    condition     = !startswith(var.cookie_domain, ".") && !startswith(var.cookie_domain, "www.")
    error_message = "cookie_domain must be the bare staging apex, for example staging.example.com, without a leading dot or www."
  }
}

variable "site_host" {
  description = "Hostname the browser lands on after sign-in and the host the Cognito redirect URI is built from, for example www.staging.carmodpicker.com. It must be cookie_domain itself or a subdomain of it."
  type        = string

  validation {
    condition     = var.site_host == var.cookie_domain || endswith(var.site_host, ".${var.cookie_domain}")
    error_message = "site_host must equal cookie_domain or end with .<cookie_domain>, otherwise the signed cookies never reach it."
  }
}

variable "additional_hosts" {
  description = "Other hostnames served by the same distribution that may complete the Cognito flow, for example the bare staging apex when it redirects to www. Each is registered as a callback URL."
  type        = list(string)
  default     = []
}

variable "allowed_emails" {
  description = "Email addresses allowed through the gate. Each becomes a Cognito user that is invited by email; nobody else can sign up. The login handler also rejects any id token whose email is not in this list."
  type        = list(string)

  validation {
    condition     = length(var.allowed_emails) > 0
    error_message = "allowed_emails must list at least one address. An empty list is a gate nobody can open, which is a broken environment rather than a private one."
  }

  validation {
    condition     = alltrue([for e in var.allowed_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every entry in allowed_emails must look like an email address."
  }

  validation {
    condition     = length(distinct([for e in var.allowed_emails : lower(e)])) == length(var.allowed_emails)
    error_message = "allowed_emails contains the same address twice (case-insensitively). Cognito usernames are the email, so the second one fails to create."
  }
}

variable "session_hours" {
  description = "How long a signed-cookie session lasts before the browser is sent back through Cognito."
  type        = number
  default     = 12

  validation {
    condition     = var.session_hours >= 1 && var.session_hours <= 168
    error_message = "session_hours must be between 1 and 168."
  }
}

variable "auth_path_prefix" {
  description = "URI prefix routed to the login Lambda. The consuming distribution must have an ordered cache behavior for <auth_path_prefix>* pointing at the login origin."
  type        = string
  default     = "/_auth/"

  validation {
    condition     = startswith(var.auth_path_prefix, "/") && endswith(var.auth_path_prefix, "/") && length(var.auth_path_prefix) > 2
    error_message = "auth_path_prefix must start and end with a slash, for example /_auth/."
  }
}

variable "api_path_prefix" {
  description = "URI prefix the viewer-request function treats as API traffic: the application handler is skipped there and an unauthenticated request gets a 401 JSON body instead of a redirect to the login page."
  type        = string
  default     = "/api/"

  validation {
    condition     = startswith(var.api_path_prefix, "/") && endswith(var.api_path_prefix, "/")
    error_message = "api_path_prefix must start and end with a slash, for example /api/."
  }
}

variable "viewer_request_handler_js" {
  description = "Optional JavaScript defining `function appHandler(event)` (sync or async) that the gate runs before its own check on non-API, non-auth paths. It may return a response object (ending the request, for example a redirect) or the possibly rewritten `event.request`. Leave empty for a plain gate."
  type        = string
  default     = ""
}

variable "cloudfront_distribution_arn" {
  description = "Optional ARN of the distribution that fronts the login Lambda, used to narrow the function URL invoke permission to that one distribution. Leave null when the same distribution consumes this module's outputs: referencing it here would be a dependency cycle, so the permission then admits any distribution in the account (arn:aws:cloudfront::<account>:distribution/*), which in a single-application staging account is the same set."
  type        = string
  default     = null
}

variable "http_api_id" {
  description = "Optional API Gateway HTTP API id. When set, a REQUEST authorizer is created on it that admits only requests carrying the origin verification header CloudFront adds; attach it to the routes with authorization_type = \"CUSTOM\"."
  type        = string
  default     = null
}

variable "http_api_attached" {
  description = <<-EOT
    Plan time known override for whether the REQUEST authorizer and its invoke permission are created
    on http_api_id. Null, the default, derives it the historic way, from http_api_id being non null,
    so a consumer that does not set this sees no plan change at all.

    Set it to a literal boolean when http_api_id is unknown at plan time, which is what happens
    whenever the HTTP API is created by the same apply that attaches the gate to it. Terraform
    refuses to plan a count derived from an unknown value at all, with Invalid count argument, and a
    null test against an unknown api id is exactly such a count. A boolean the consumer writes from
    inputs it already knows, for example its own staging gate switch, is always known, so a fresh
    account can create the API and attach the authorizer in a single apply.

    http_api_id is still required when this is true. It is read at apply time rather than at plan
    time, so an unknown id does not fail the plan.
  EOT

  type    = bool
  default = null
}

variable "origin_verify_header_name" {
  description = "Name of the header CloudFront adds to API origin requests and the HTTP API authorizer checks."
  type        = string
  default     = "x-origin-verify"
}

variable "invite_login_url" {
  description = "URL placed in the Cognito invitation email. Defaults to https://<site_host>/."
  type        = string
  default     = null
}

variable "mfa_configuration" {
  description = "Cognito MFA setting for the gate's user pool: OFF, OPTIONAL or ON. Software token MFA is what gets enabled."
  type        = string
  default     = "OFF"

  validation {
    condition     = contains(["OFF", "OPTIONAL", "ON"], var.mfa_configuration)
    error_message = "mfa_configuration must be OFF, OPTIONAL or ON."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the two Lambda functions in days. 0 means never expire."
  type        = number
  default     = 7

  validation {
    condition = contains([
      0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096,
      1827, 2192, 2557, 2922, 3288, 3653,
    ], var.log_retention_days)
    error_message = "log_retention_days must be one of the values CloudWatch Logs accepts: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
}

variable "identity_jwt" {
  description = <<-EOT
    Make the gate's authorizer also require a valid identity access token on the routes named in
    identity_jwt_route_keys. Null, the default, leaves the authorizer checking only the gate
    credentials, which is exactly what it does today.

    Fields:
      issuer    the identity issuer, byte for byte the string the identity module was given. The
                JWKS URL is derived from it as <issuer>/.well-known/jwks.json unless jwks_url says
                otherwise
      audience  the aud claim the identity function stamps. A token whose aud is anything else is
                refused, which is what stops a production token opening staging
      jwks_url            optional override of the derived JWKS URL
      jwks_ttl_seconds    optional, how long a fetched key set is reused. Default 300
      clock_skew_seconds  optional leeway on exp and nbf, for skew between the signer and this
                          function. Default 60
      api_key_prefixes    optional list of bearer token prefixes, for example ["wpk_"]. A bearer
                          token on a JWT route that starts with one of these is allowed through with
                          no claims context, so the function must verify the key itself. Empty, the
                          default, keeps today's behaviour where any non-JWT bearer is denied

    Staging only; production enforces the same token through the http-api module's identity_jwt
    input. The gate credential check still runs first, so this only narrows access.
  EOT

  type = object({
    issuer             = string
    audience           = string
    jwks_url           = optional(string)
    jwks_ttl_seconds   = optional(number)
    clock_skew_seconds = optional(number)
    api_key_prefixes   = optional(list(string), [])
  })
  default = null

  validation {
    condition     = var.identity_jwt == null || startswith(coalesce(try(var.identity_jwt.issuer, null), "https://x"), "https://")
    error_message = "identity_jwt.issuer must be an https URL."
  }

  validation {
    condition     = var.identity_jwt == null || !endswith(coalesce(try(var.identity_jwt.issuer, null), "x"), "/")
    error_message = "identity_jwt.issuer must not end with a trailing slash: the JWKS URL is built by appending /.well-known/jwks.json, and a trailing slash yields a double slash that fetches nothing."
  }

  validation {
    condition     = var.identity_jwt == null || try(var.identity_jwt.audience, "") != ""
    error_message = "identity_jwt.audience must not be empty: it is what the token's aud claim is matched against."
  }

  validation {
    condition     = var.identity_jwt == null || coalesce(try(var.identity_jwt.jwks_ttl_seconds, null), 300) > 0
    error_message = "identity_jwt.jwks_ttl_seconds must be greater than zero."
  }

  validation {
    condition     = var.identity_jwt == null || coalesce(try(var.identity_jwt.clock_skew_seconds, null), 60) >= 0
    error_message = "identity_jwt.clock_skew_seconds must not be negative."
  }

  validation {
    condition     = var.identity_jwt == null || alltrue([for p in coalesce(try(var.identity_jwt.api_key_prefixes, null), []) : trimspace(p) != ""])
    error_message = "identity_jwt.api_key_prefixes must not contain an empty prefix: an empty prefix matches every bearer token and lets any string past the token check."
  }

  validation {
    condition     = var.identity_jwt == null || alltrue([for p in coalesce(try(var.identity_jwt.api_key_prefixes, null), []) : !startswith(lower(trimspace(p)), "ey")])
    error_message = "identity_jwt.api_key_prefixes must not start with ey: that is the base64url of a JWT header, so such a prefix would pass real access tokens through unverified."
  }
}

variable "identity_jwt_route_keys" {
  description = <<-EOT
    The API Gateway route keys that require an identity access token, for example
    ["GET /api/auth/me", "ANY /api/v1/{proxy+}"]. Empty, the default, means no route does and the
    authorizer behaves exactly as it did before this input existed.

    Pass the http-api module's identity_jwt_route_keys output straight into this. That output is the
    set of routes marked require_identity_jwt, already sorted, and a route key is the same string on
    both sides by construction: it is the map key in that module's routes and it is
    requestContext.routeKey in this authorizer's event.

    The route key is the signal rather than a second authorizer resource because a payload 2.0
    authorizer event does not name the authorizer that invoked the function. routeArn is a route ARN
    and there is no authorizer id anywhere in the event, so two authorizers over one Lambda would be
    indistinguishable from inside it.

    A key here that names no route on the API is inert rather than an error: this module is not
    given the API's route list and cannot tell the difference between a typo and a route that has
    not been added yet.
  EOT

  type    = list(string)
  default = []

  validation {
    condition = alltrue([
      for k in var.identity_jwt_route_keys :
      k == "$default" || can(regex("^(ANY|GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /", k))
    ])
    error_message = "Every identity_jwt_route_keys entry must be an API Gateway route key, <METHOD> <path>, exactly as the http-api module's routes are keyed."
  }

  validation {
    condition     = !contains(var.identity_jwt_route_keys, "$default")
    error_message = "Do not require an identity token on $default. It is the catch-all for every path no explicit route claims, so marking it turns enforcement on for paths nobody has listed, including ones that have to answer anonymously."
  }

  validation {
    condition     = alltrue([for k in var.identity_jwt_route_keys : !strcontains(k, ",")])
    error_message = "A route key must not contain a comma: the list is passed to the authorizer as one comma separated environment variable."
  }

  validation {
    condition     = length(distinct(var.identity_jwt_route_keys)) == length(var.identity_jwt_route_keys)
    error_message = "identity_jwt_route_keys contains the same route key twice."
  }
}

variable "identity_anonymous_path_prefixes" {
  description = <<-EOT
    Paths the gate authorizer admits with no gate credential and no identity token, matched as
    prefixes of the request path.

    Null, the default, renders the issuer's `.well-known` subtree when identity enforcement is on
    and nothing at all when it is off. That default exists because of a fail-closed defect: the
    authorizer verifies tokens against the issuer's JWKS, and in the gate topology the issuer is the
    same API the authorizer guards, so the authorizer's own fetch went back through the gate with no
    credentials, was refused, and every identity token was denied. The authorizer now sends the
    origin verification header on that fetch, and these prefixes make the discovery document and the
    JWKS reachable to every other verifier as well.

    Only public key material belongs here. The two `.well-known` documents are published so that
    anyone can verify a token this issuer signed: they carry no user data and mutate nothing. Adding
    an application path to this list is a hole straight past the gate.

    Pass [] to render no exemption at all.
  EOT

  type    = list(string)
  default = null

  validation {
    condition = var.identity_anonymous_path_prefixes == null || alltrue([
      for p in var.identity_anonymous_path_prefixes : startswith(p, "/")
    ])
    error_message = "Every identity_anonymous_path_prefixes entry must start with a slash."
  }
}
