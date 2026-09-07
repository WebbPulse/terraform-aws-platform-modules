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
  description = "CloudWatch Logs retention for the two Lambda functions."
  type        = number
  default     = 14
}
