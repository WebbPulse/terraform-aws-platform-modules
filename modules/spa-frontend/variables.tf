variable "name" {
  description = "Base name for everything this module creates, for example carmodpicker-production-frontend. It is the S3 bucket name and the origin access control name unless bucket_name or origin_access_control_name override them, so it has to be a valid bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 63 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit, so it can be used as an S3 bucket name."
  }
}

variable "bucket_name" {
  description = "S3 bucket that holds the built site. Defaults to name."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.bucket_name == null || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3 to 63 characters of lowercase letters, digits, dots and hyphens, starting and ending with a letter or digit."
  }
}

variable "origin_access_control_name" {
  description = "Name of the CloudFront origin access control that signs requests to the bucket. Defaults to name."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.origin_access_control_name == null || can(regex("^.{1,64}$", var.origin_access_control_name))
    error_message = "origin_access_control_name must be 1 to 64 characters."
  }
}

variable "bucket_policy_sid" {
  description = "Statement id of the bucket policy statement that lets CloudFront read the bucket. Only matters when adopting an existing bucket whose policy already has a Sid: match it and the policy plans as a no-op."
  type        = string
  default     = "AllowCloudFrontServicePrincipal"

  validation {
    condition     = can(regex("^[A-Za-z0-9]{1,100}$", var.bucket_policy_sid))
    error_message = "bucket_policy_sid must be 1 to 100 letters and digits; S3 rejects anything else."
  }
}

variable "origin_id" {
  description = "origin_id of the S3 origin inside the distribution. Changing it on an existing distribution is an in-place update, but every behavior references it, so match the current value when adopting."
  type        = string
  default     = "s3-frontend"

  validation {
    condition     = length(var.origin_id) > 0 && length(var.origin_id) <= 128
    error_message = "origin_id must be 1 to 128 characters."
  }
}

variable "aliases" {
  description = "Alternate domain names served by the distribution, for example [\"www.example.com\", \"example.com\"]. The first entry is treated as the canonical host and becomes the frontend_url output. Empty means the site is served from the CloudFront default hostname with the default certificate."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for h in var.aliases : can(regex("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", h))])
    error_message = "Every alias must be a lowercase DNS hostname without a trailing dot, optionally starting with *."
  }

  validation {
    condition     = length(distinct(var.aliases)) == length(var.aliases)
    error_message = "aliases contains a duplicate hostname."
  }
}

variable "acm_certificate_arn" {
  description = "ARN of a validated ACM certificate in us-east-1 that covers every alias. Required when aliases is non-empty and ignored when it is empty. This module does not create the certificate: see the README for why it stays with the consumer."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.acm_certificate_arn == null || can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be an ACM certificate in us-east-1; CloudFront accepts certificates from no other region."
  }

  validation {
    condition     = length(var.aliases) == 0 || var.acm_certificate_arn != null
    error_message = "acm_certificate_arn is required when aliases is set: CloudFront refuses alternate domain names on the default certificate."
  }
}

variable "minimum_protocol_version" {
  description = "Minimum TLS version viewers must speak when a custom certificate is in use. Ignored without aliases."
  type        = string
  default     = "TLSv1.2_2021"

  validation {
    condition     = contains(["TLSv1.2_2018", "TLSv1.2_2019", "TLSv1.2_2021", "TLSv1.3_2025"], var.minimum_protocol_version)
    error_message = "minimum_protocol_version must be one of TLSv1.2_2018, TLSv1.2_2019, TLSv1.2_2021 or TLSv1.3_2025."
  }
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "default_root_object" {
  description = "Object served for the bare root URL. Also the SPA shell that 403 and 404 responses fall back to, and the path of the unsigned fallback behavior when an access gate is attached."
  type        = string
  default     = "index.html"

  validation {
    condition     = length(var.default_root_object) > 0 && !startswith(var.default_root_object, "/")
    error_message = "default_root_object must be a non-empty object key without a leading slash, for example index.html."
  }
}

variable "ipv6_enabled" {
  description = "Whether the distribution answers over IPv6. Note that AAAA records are only created when create_aaaa_records is also true."
  type        = bool
  default     = true
}

variable "comment" {
  description = "Optional comment shown in the CloudFront console."
  type        = string
  default     = null
  nullable    = true
}

variable "cache_mode" {
  description = "How the S3 behaviors configure caching. policies uses cache_policy_id, origin_request_policy_id and response_headers_policy_id (the current CloudFront model). forwarded_values uses the legacy forwarded_values block plus min_ttl, default_ttl and max_ttl from the forwarded_values variable. Switching an existing distribution between the two is an in-place update, not a replacement, but match the current model when adopting."
  type        = string
  default     = "policies"

  validation {
    condition     = contains(["policies", "forwarded_values"], var.cache_mode)
    error_message = "cache_mode must be policies or forwarded_values."
  }
}

variable "index_cache_mode" {
  description = "How the SPA shell behavior at /<default_root_object> configures caching. Defaults to cache_mode, so a consumer that never sets it sees no change. Set it when the live distribution mixes the two models, which is what happens when a hand-written default behavior kept its legacy forwarded_values block while the SPA shell behavior was added later with a managed cache policy. Only meaningful when access_gate is set, because the SPA shell behavior exists only then."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.index_cache_mode == null || contains(["policies", "forwarded_values"], var.index_cache_mode)
    error_message = "index_cache_mode must be policies or forwarded_values, or null to follow cache_mode."
  }
}

variable "index_cache_policies" {
  description = "Cache, origin request and response headers policies for the SPA shell behavior when its effective cache mode is policies. Leave it null and the behavior reuses cache_policy_id, origin_request_policy_id and response_headers_policy_id, which is what every consumer written before this input got. Set it to pin the SPA shell behavior on its own: { cache_policy_id = \"658327ea-f89d-4fab-a63d-7e88639e58f6\" } gives that behavior a cache policy and no origin request policy, which is the shape a hand-written SPA shell behavior usually has. A null response_headers_policy_id member falls back to the policy the other S3 behaviors carry, so the shell is never served without security headers unless security_headers.enabled is false and response_headers_policy_id is null."
  type = object({
    cache_policy_id            = optional(string)
    origin_request_policy_id   = optional(string)
    response_headers_policy_id = optional(string)
  })
  default  = null
  nullable = true

  validation {
    condition     = var.index_cache_policies == null || var.index_cache_policies.cache_policy_id != null
    error_message = "index_cache_policies.cache_policy_id is required when index_cache_policies is set; CloudFront needs a cache policy on a behavior that uses the policy model."
  }
}

variable "cache_policy_id" {
  description = "Cache policy for the S3 behaviors when cache_mode is policies. Defaults to the AWS managed CachingOptimized policy."
  type        = string
  default     = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  nullable    = true

  validation {
    condition     = var.cache_mode != "policies" || var.cache_policy_id != null
    error_message = "cache_policy_id is required when cache_mode is policies."
  }
}

variable "origin_request_policy_id" {
  description = "Optional origin request policy for the S3 behaviors when cache_mode is policies, for example the AWS managed CORS-S3Origin policy 88a5eaf4-2fd4-4709-b370-b4c650ea3fcf."
  type        = string
  default     = null
  nullable    = true
}

variable "response_headers_policy_id" {
  description = "Response headers policy for the S3 behaviors, in either cache_mode: the default behavior, every public_paths behavior and the SPA shell behavior. Null, the default, attaches the policy this module builds from security_headers. Set it to use your own policy instead, for example the AWS managed SecurityHeadersPolicy 67f7725c-6f97-4210-82d7-5512b31e9d03; it always wins, and the module then builds no policy of its own."
  type        = string
  default     = null
  nullable    = true
}

variable "forwarded_values" {
  description = "Legacy cache settings for the S3 behaviors, used only when cache_mode is forwarded_values. The defaults reproduce a distribution that forwards no query string and no cookies with TTLs of 0, 86400 and 31536000 seconds."
  type = object({
    query_string    = optional(bool, false)
    cookies_forward = optional(string, "none")
    headers         = optional(list(string))
    min_ttl         = optional(number, 0)
    default_ttl     = optional(number, 86400)
    max_ttl         = optional(number, 31536000)
  })
  default = {}

  validation {
    condition     = contains(["none", "all", "whitelist"], var.forwarded_values.cookies_forward)
    error_message = "forwarded_values.cookies_forward must be none, all or whitelist."
  }

  validation {
    condition     = var.forwarded_values.min_ttl <= var.forwarded_values.default_ttl && var.forwarded_values.default_ttl <= var.forwarded_values.max_ttl
    error_message = "forwarded_values TTLs must satisfy min_ttl <= default_ttl <= max_ttl."
  }
}

variable "spa_fallback_error_codes" {
  description = "Origin error codes that CloudFront turns into a 200 response carrying the default root object, so client-side routes resolve. S3 returns 403 for missing keys when the bucket denies ListBucket, which is why both 403 and 404 are listed."
  type        = list(number)
  default     = [403, 404]

  validation {
    condition     = alltrue([for c in var.spa_fallback_error_codes : contains([400, 403, 404, 405, 414, 416, 500, 501, 502, 503, 504], c)])
    error_message = "spa_fallback_error_codes may only contain codes CloudFront supports for custom error responses: 400, 403, 404, 405, 414, 416, 500, 501, 502, 503, 504."
  }
}

variable "error_caching_min_ttl" {
  description = "Seconds CloudFront caches the SPA fallback response for each error code in spa_fallback_error_codes."
  type        = number
  default     = 0

  validation {
    condition     = var.error_caching_min_ttl >= 0
    error_message = "error_caching_min_ttl must be zero or positive."
  }
}

variable "viewer_request_function_arn" {
  description = "Optional CloudFront Function to associate as viewer-request on the default behavior, for example an apex to www redirect or a URI rewrite. The function is not created here so consumers keep their own code. Ignored when access_gate is set: the gate's function wraps the application handler and takes its place."
  type        = string
  default     = null
  nullable    = true
}

variable "access_gate" {
  description = "Outputs of a staging-access-gate module instance, minus the origin verification header value, which is a separate input. When set, the distribution gains the login origin, an ordered behavior for the auth path pattern, an unsigned behavior for the SPA shell, trusted_key_groups on the default behavior, and the gate's viewer-request function on every behavior. It also maps 403 to the gate's sign-in-required page on the login origin instead of the SPA shell, drops 403 from the SPA fallback, and grants CloudFront s3:ListBucket so a missing key is a 404 that still falls back to the shell. session_required_path defaults to <auth_path_pattern without its trailing *>session-required, which is what the gate's session_required_path output holds. The api_origin_domain_name, api_path_pattern and origin_verify_header_name members are optional and null by default: leave them null and the frontend calls the API directly at its own hostname, which is the shape the gate's authorizer is built for. Set all three to also proxy the API through this distribution; see the api_origin_domain_name note below. The secret is kept out of this object on purpose: an object with one sensitive member is sensitive as a whole at the module boundary, which would redact every path pattern, origin id and TTL read out of it and make the distribution plan a spurious in-place update where only the sensitivity marks differ."
  type = object({
    key_group_id                                           = string
    viewer_request_function_arn                            = string
    login_origin_domain_name                               = string
    login_origin_access_control_id                         = string
    auth_path_pattern                                      = string
    cache_policy_id_caching_disabled                       = string
    origin_request_policy_id_all_viewer_except_host_header = string
    login_origin_id                                        = optional(string, "access-gate-login")
    session_required_path                                  = optional(string)

    api_origin_domain_name    = optional(string)
    api_path_pattern          = optional(string)
    origin_verify_header_name = optional(string)
    api_origin_id             = optional(string, "api")
  })
  default  = null
  nullable = true

  validation {
    condition     = var.access_gate == null || can(regex("^/.+\\*$", var.access_gate.auth_path_pattern))
    error_message = "access_gate.auth_path_pattern must be a CloudFront path pattern such as /_auth/*."
  }

  validation {
    condition     = var.access_gate == null ? true : var.access_gate.session_required_path == null ? true : startswith(var.access_gate.session_required_path, trimsuffix(var.access_gate.auth_path_pattern, "*"))
    error_message = "access_gate.session_required_path must sit under auth_path_pattern, so CloudFront fetches the 403 page from the login origin through the unsigned auth behavior."
  }

  validation {
    condition = var.access_gate == null || (
      (var.access_gate.api_origin_domain_name == null && var.access_gate.api_path_pattern == null && var.access_gate.origin_verify_header_name == null) ||
      (var.access_gate.api_origin_domain_name != null && var.access_gate.api_path_pattern != null && var.access_gate.origin_verify_header_name != null)
    )
    error_message = "access_gate.api_origin_domain_name, api_path_pattern and origin_verify_header_name go together: set all three to proxy the API through this distribution, or none of them to have the frontend call the API host directly."
  }

  validation {
    condition     = var.access_gate == null || var.access_gate.api_path_pattern == null || can(regex("^/.+\\*$", var.access_gate.api_path_pattern))
    error_message = "access_gate.api_path_pattern must be a CloudFront path pattern such as /api/*."
  }

  validation {
    condition     = var.access_gate == null || var.access_gate.login_origin_id != var.origin_id
    error_message = "access_gate.login_origin_id and origin_id must be different strings; they are two origins on one distribution."
  }

  validation {
    condition = var.access_gate == null || var.access_gate.api_origin_domain_name == null || (
      var.access_gate.api_origin_id != var.origin_id && var.access_gate.api_origin_id != var.access_gate.login_origin_id
    )
    error_message = "In proxy mode access_gate.api_origin_id must differ from origin_id and from access_gate.login_origin_id."
  }
}

variable "public_paths" {
  description = "CloudFront path patterns served from the S3 origin without the access gate, for documents that have to answer anonymously such as /.well-known/terraform.json. With access_gate set, each becomes an ordered behavior ahead of every other, with the default behavior's cache settings but no trusted_key_groups and no viewer-request function. Without a gate the default behavior already serves them anonymously, so nothing is rendered. Only public content belongs here: every object matching a pattern is readable by anyone."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for p in var.public_paths : startswith(p, "/") && length(p) > 1])
    error_message = "Every public_paths entry must be a CloudFront path pattern starting with a slash, such as /.well-known/terraform.json."
  }

  validation {
    condition     = alltrue([for p in var.public_paths : !contains(["/*", "/**", "/*.*"], p)])
    error_message = "public_paths must not match the whole site: that would take the entire distribution out from behind the access gate."
  }

  validation {
    condition     = length(distinct(var.public_paths)) == length(var.public_paths)
    error_message = "public_paths contains the same pattern twice."
  }

  validation {
    condition     = var.access_gate == null || !contains(var.public_paths, try(var.access_gate.auth_path_pattern, ""))
    error_message = "public_paths must not repeat access_gate.auth_path_pattern; that path belongs to the gate's login origin."
  }
}

variable "access_gate_origin_verify_header_value" {
  description = "Value of the origin verification header CloudFront sends to the API origin, normally module.gate.origin_verify_header_value. Required only in proxy mode, that is when access_gate sets api_origin_domain_name; ignored otherwise. It is a top-level input rather than a member of access_gate so that its sensitive mark stays on this one value instead of spreading to every attribute of the object."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true

  validation {
    condition     = var.access_gate == null || var.access_gate.api_origin_domain_name == null || var.access_gate_origin_verify_header_value != null
    error_message = "access_gate_origin_verify_header_value is required when access_gate sets api_origin_domain_name: the API origin needs the header the gate's authorizer checks."
  }
}

variable "create_dns_records" {
  description = "Create Route 53 alias records for the hostnames in dns_records, in zone_id, using this module's aws provider. Leave false when the records live in a zone another account owns; see the README."
  type        = bool
  default     = false
}

variable "zone_id" {
  description = "Route 53 hosted zone that receives the alias records. Required when create_dns_records is true."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.create_dns_records || var.zone_id != null
    error_message = "zone_id is required when create_dns_records is true."
  }
}

variable "dns_records" {
  description = "Hostnames to point at the distribution, keyed by a stable label that becomes the resource index, for example { www = \"www.example.com\", apex = \"example.com\" }. Labels rather than hostnames keep resource addresses identical between environments whose hostnames differ. Every hostname must also be in aliases."
  type        = map(string)
  default     = {}

  validation {
    condition     = !var.create_dns_records || length(var.dns_records) > 0
    error_message = "dns_records must name at least one hostname when create_dns_records is true."
  }

  validation {
    condition     = !var.create_dns_records || alltrue([for h in values(var.dns_records) : contains(var.aliases, h)])
    error_message = "Every hostname in dns_records must also be listed in aliases, otherwise CloudFront answers it with a 403."
  }

  validation {
    condition     = alltrue([for k in keys(var.dns_records) : can(regex("^[a-z0-9_-]+$", k))])
    error_message = "dns_records keys must be lowercase letters, digits, underscores and hyphens; they become resource index keys."
  }
}

variable "create_aaaa_records" {
  description = "Also create AAAA alias records for dns_records. Off by default because the adopting estates only have A records today; turning it on is a pure addition."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the bucket and the distribution, on top of any provider default_tags."
  type        = map(string)
  default     = {}
}

variable "distribution_tags" {
  description = "Extra tags for the distribution only, merged over tags. Lets an adopter reproduce a Name tag that exists on the distribution but not on the bucket."
  type        = map(string)
  default     = {}
}

variable "viewer_request_function" {
  description = "Build the viewer-request CloudFront Function in this module instead of taking one by ARN. canonical_host picks which hostname wins: apex redirects www.<domain> to <domain>, www redirects <domain> to www.<domain>, and none writes no redirect at all and leaves only the SPA URI rewrite. domain is the registrable domain without a www prefix. Null keeps today's behaviour, where the function is the caller's and arrives through viewer_request_function_arn. Setting both is refused. name defaults to <name>-uri-rewrite, which is what a product whose module name is <prefix>-frontend already calls its function; name is immutable on a CloudFront Function, so an adopter with a different existing name sets it here or gets a replacement."
  type = object({
    domain         = string
    canonical_host = optional(string, "apex")
    name           = optional(string)
    comment        = optional(string)
    publish        = optional(bool, true)
    runtime        = optional(string, "cloudfront-js-2.0")
  })
  default  = null
  nullable = true

  validation {
    condition     = var.viewer_request_function == null || contains(["apex", "www", "none"], coalesce(try(var.viewer_request_function.canonical_host, null), "apex"))
    error_message = "viewer_request_function.canonical_host must be apex, www or none."
  }

  validation {
    condition     = var.viewer_request_function == null || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.viewer_request_function.domain))
    error_message = "viewer_request_function.domain must be a bare domain name."
  }

  validation {
    condition     = var.viewer_request_function == null || !startswith(var.viewer_request_function.domain, "www.")
    error_message = "viewer_request_function.domain is the registrable domain without a www prefix; canonical_host decides which side of it is canonical."
  }
}

variable "security_headers" {
  description = "The response headers policy this module builds and attaches to every S3 behavior, in both cache modes, when response_headers_policy_id is null. It sends Strict-Transport-Security (max-age hsts_max_age_seconds, includeSubDomains unless hsts_include_subdomains is false, preload only when hsts_preload is true), X-Content-Type-Options nosniff, X-Frame-Options DENY, Referrer-Policy strict-origin-when-cross-origin, and a Content-Security-Policy built from an SPA baseline: default-src, connect-src, script-src, base-uri and form-action 'self'; img-src and font-src 'self' data:; style-src 'self' 'unsafe-inline'; object-src and frame-ancestors 'none'. The lists under content_security_policy add sources to their directive, and frame_src, media_src and worker_src add that directive only when non-empty. content_security_policy.mode is report_only by default, which sends the policy as Content-Security-Policy-Report-Only so browsers log violations without blocking anything; enforce sends it as Content-Security-Policy; off sends neither. report_uri adds a report-uri directive. enabled = false builds no policy, which with a null response_headers_policy_id leaves the S3 behaviors with no response headers policy, as before 2.37. name defaults to <name>-security-headers and must be unique in the account."
  type = object({
    enabled                 = optional(bool, true)
    name                    = optional(string)
    hsts_max_age_seconds    = optional(number, 31536000)
    hsts_include_subdomains = optional(bool, true)
    hsts_preload            = optional(bool, false)
    content_security_policy = optional(object({
      mode        = optional(string, "report_only")
      connect_src = optional(list(string), [])
      img_src     = optional(list(string), [])
      script_src  = optional(list(string), [])
      style_src   = optional(list(string), [])
      font_src    = optional(list(string), [])
      frame_src   = optional(list(string), [])
      media_src   = optional(list(string), [])
      worker_src  = optional(list(string), [])
      form_action = optional(list(string), [])
      report_uri  = optional(string)
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["enforce", "report_only", "off"], var.security_headers.content_security_policy.mode)
    error_message = "security_headers.content_security_policy.mode must be enforce, report_only or off."
  }

  validation {
    condition     = var.security_headers.hsts_max_age_seconds >= 0 && floor(var.security_headers.hsts_max_age_seconds) == var.security_headers.hsts_max_age_seconds
    error_message = "security_headers.hsts_max_age_seconds must be a whole number of seconds, zero or more."
  }

  validation {
    condition     = !var.security_headers.hsts_preload || (var.security_headers.hsts_include_subdomains && var.security_headers.hsts_max_age_seconds >= 31536000)
    error_message = "security_headers.hsts_preload needs hsts_include_subdomains and an hsts_max_age_seconds of at least 31536000; the preload list refuses anything less."
  }

  validation {
    condition     = var.security_headers.name == null || can(regex("^[A-Za-z0-9_-]{1,128}$", var.security_headers.name))
    error_message = "security_headers.name must be 1 to 128 letters, digits, hyphens and underscores."
  }

  validation {
    condition = alltrue([
      for source in flatten([
        var.security_headers.content_security_policy.connect_src,
        var.security_headers.content_security_policy.img_src,
        var.security_headers.content_security_policy.script_src,
        var.security_headers.content_security_policy.style_src,
        var.security_headers.content_security_policy.font_src,
        var.security_headers.content_security_policy.frame_src,
        var.security_headers.content_security_policy.media_src,
        var.security_headers.content_security_policy.worker_src,
        var.security_headers.content_security_policy.form_action,
        compact([var.security_headers.content_security_policy.report_uri]),
      ]) : can(regex("^[^\\s;,]+$", source))
    ])
    error_message = "Every security_headers.content_security_policy source must be a single non-empty token with no whitespace, semicolon or comma, such as https://api.example.com or 'sha256-...'; a semicolon would start a new directive."
  }
}
