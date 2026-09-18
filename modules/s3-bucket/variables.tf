variable "bucket" {
  description = "Name of the bucket, for example \"webbpulse-terraform-staging-state\". Changing it replaces the bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket))
    error_message = "bucket must be 3 to 63 characters of lowercase letters, digits, hyphens and dots, starting and ending with a letter or digit."
  }
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket while it still holds objects. The bucket is versioned by default, so leaving this false means a destroy fails until the objects and their noncurrent versions are removed on purpose."
  type        = bool
  default     = false
}

variable "versioning_status" {
  description = "Versioning state of the bucket: \"Enabled\" or \"Suspended\". Enabled is the default because a bucket holding Terraform state has no other way back from a bad write."
  type        = string
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Suspended"], var.versioning_status)
    error_message = "versioning_status must be Enabled or Suspended."
  }
}

variable "object_ownership" {
  description = "Ownership controls setting: \"BucketOwnerEnforced\" turns ACLs off entirely, which is what this module is built for. The other two values exist only to adopt a bucket that still relies on ACLs."
  type        = string
  default     = "BucketOwnerEnforced"

  validation {
    condition     = contains(["BucketOwnerEnforced", "BucketOwnerPreferred", "ObjectWriter"], var.object_ownership)
    error_message = "object_ownership must be BucketOwnerEnforced, BucketOwnerPreferred or ObjectWriter."
  }
}

variable "kms_key_arn" {
  description = "ARN of an existing KMS key encrypting every object. Null with create_kms_key false leaves the bucket on SSE-S3, which costs nothing per request. Mutually exclusive with create_kms_key."
  type        = string
  default     = null
}

variable "create_kms_key" {
  description = "Create a customer managed KMS key for this bucket, with rotation on and a policy granting the account root plus kms_key_extra_principal_arns. Mutually exclusive with kms_key_arn."
  type        = bool
  default     = false

  validation {
    condition     = !(var.create_kms_key && var.kms_key_arn != null)
    error_message = "create_kms_key and kms_key_arn are mutually exclusive: the module either creates a key or encrypts with the one it is given."
  }
}

variable "kms_key_description" {
  description = "Description of the created key. Null describes it after the bucket."
  type        = string
  default     = null
}

variable "kms_key_rotation_enabled" {
  description = "Yearly automatic rotation of the created key. AWS keeps every previous backing key, so an object encrypted under an older one still decrypts."
  type        = bool
  default     = true
}

variable "kms_key_deletion_window_in_days" {
  description = "Days AWS waits before destroying the created key after a scheduled deletion. Nothing in the bucket can be read once the key is gone, so a short window on a state bucket is a hazard."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_in_days >= 7 && var.kms_key_deletion_window_in_days <= 30 && floor(var.kms_key_deletion_window_in_days) == var.kms_key_deletion_window_in_days
    error_message = "kms_key_deletion_window_in_days must be a whole number from 7 to 30."
  }
}

variable "kms_key_extra_principal_arns" {
  description = "Principal ARNs the created key's policy grants encrypt and decrypt to, on top of the account root's full access. A role in another account reading this bucket needs an entry here as well as a bucket policy statement."
  type        = list(string)
  default     = []
}

variable "kms_key_policy_json" {
  description = "Complete policy JSON for the created key, replacing the generated one. Use it only when the generated policy cannot express the grant; an incomplete policy can lock the key out of its own account."
  type        = string
  default     = null
}

variable "create_kms_key_alias" {
  description = "Create an alias for the created key. The alias is what a console user recognises the key by."
  type        = bool
  default     = true
}

variable "kms_key_alias" {
  description = "Alias name for the created key, with or without the \"alias/\" prefix. Null names it \"alias/<bucket>\"."
  type        = string
  default     = null
}

variable "bucket_key_enabled" {
  description = "S3 Bucket Keys on the encryption rule, which cut the per request KMS charge by orders of magnitude. Only meaningful with a KMS key; null leaves the attribute unset."
  type        = bool
  default     = true
}

variable "enable_tls_only_policy" {
  description = "Add a bucket policy statement denying every request that did not arrive over TLS. It denies on aws:SecureTransport false only, so it never touches a plain PutObject made over HTTPS."
  type        = bool
  default     = true
}

variable "enable_deny_unencrypted_uploads_policy" {
  description = "Add a bucket policy statement denying a PutObject that does not carry the expected server-side encryption header. Off by default: a client that omits the header still gets the bucket default applied, and the statement breaks any writer that does not set it explicitly."
  type        = bool
  default     = false
}

variable "extra_policy_statements" {
  description = "Additional bucket policy statements, merged into the generated policy in order. Each is an object in the IAM policy shape, so a caller can grant a cross-account reader or deny a prefix without replacing the whole policy. An empty list plus both toggles off writes no bucket policy at all."
  type        = any
  default     = []

  validation {
    condition     = can(tolist(var.extra_policy_statements))
    error_message = "extra_policy_statements must be a list of policy statement objects."
  }
}

variable "lifecycle_rules" {
  description = <<-EOT
    Lifecycle rules keyed by rule id. Each value describes one rule:

      enabled  whether the rule is active. Defaults to true.
      prefix   key prefix the rule applies to, or null for the whole bucket.
      tags     object tags the rule filters on, combined with prefix through an "and" block.
      noncurrent_version_expiration_days  days a noncurrent version is kept before deletion.
      newer_noncurrent_versions  noncurrent versions kept regardless of age, so a busy prefix
               keeps a rollback target even past the expiry window.
      abort_incomplete_multipart_upload_days  days before S3 aborts a stalled multipart upload
               and reclaims the parts, which are billed as storage but invisible in a listing.
      expiration_days  days a current version is kept. Leave it null on a bucket holding state.
      expired_object_delete_marker  clean up a delete marker left with no versions behind it.
      transitions  list of { days, storage_class } moving a current version to another class.
      noncurrent_version_transitions  the same for noncurrent versions.

    Every field is optional, but a rule that sets none of the actions is rejected.
  EOT

  type = map(object({
    enabled                                = optional(bool, true)
    prefix                                 = optional(string)
    tags                                   = optional(map(string), {})
    noncurrent_version_expiration_days     = optional(number)
    newer_noncurrent_versions              = optional(number)
    abort_incomplete_multipart_upload_days = optional(number)
    expiration_days                        = optional(number)
    expired_object_delete_marker           = optional(bool)
    transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
    noncurrent_version_transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules :
      r.noncurrent_version_expiration_days != null ||
      r.abort_incomplete_multipart_upload_days != null ||
      r.expiration_days != null ||
      r.expired_object_delete_marker != null ||
      length(r.transitions) > 0 ||
      length(r.noncurrent_version_transitions) > 0
    ])
    error_message = "every lifecycle rule must set at least one action; S3 rejects a rule that does nothing."
  }

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules : alltrue([
        for t in concat(r.transitions, r.noncurrent_version_transitions) :
        contains(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"], t.storage_class)
      ])
    ])
    error_message = "every transition storage_class must be STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER_IR, GLACIER or DEEP_ARCHIVE."
  }

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules : alltrue([
        for d in [r.noncurrent_version_expiration_days, r.abort_incomplete_multipart_upload_days, r.expiration_days, r.newer_noncurrent_versions] :
        d == null ? true : d >= 1 && floor(d) == d
      ])
    ])
    error_message = "lifecycle rule day and version counts must be whole numbers of at least 1."
  }

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules : alltrue([
        for t in concat(r.transitions, r.noncurrent_version_transitions) :
        t.days >= 0 && floor(t.days) == t.days
      ])
    ])
    error_message = "every transition days value must be a whole number of at least 0."
  }

  validation {
    condition     = alltrue([for k, _ in var.lifecycle_rules : length(k) > 0 && length(k) <= 255])
    error_message = "every lifecycle rule id must be 1 to 255 characters."
  }
}

variable "enable_eventbridge_notifications" {
  description = "Send every object-level event in this bucket to the default EventBridge bus. This is the notification shape that does not need a per-target bucket notification configuration, so two consumers cannot clobber each other's wiring."
  type        = bool
  default     = false
}

variable "cors_rules" {
  description = <<-EOT
    CORS rules, in order. Each value describes one rule:

      allowed_methods  HTTP methods the browser may use: GET, PUT, POST, DELETE or HEAD.
      allowed_origins  origins the rule answers, or ["*"] for any.
      allowed_headers  request headers a preflight may declare.
      expose_headers   response headers the browser is allowed to read.
      max_age_seconds  how long a browser may cache the preflight answer.
      id               rule id, for identifying it in the console.

    Empty writes no CORS configuration at all, which is what a bucket nothing fetches
    cross-origin wants.
  EOT

  type = list(object({
    allowed_methods = list(string)
    allowed_origins = list(string)
    allowed_headers = optional(list(string), [])
    expose_headers  = optional(list(string), [])
    max_age_seconds = optional(number)
    id              = optional(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.cors_rules : alltrue([
        for m in r.allowed_methods : contains(["GET", "PUT", "POST", "DELETE", "HEAD"], m)
      ])
    ])
    error_message = "every CORS allowed_methods entry must be GET, PUT, POST, DELETE or HEAD."
  }

  validation {
    condition     = alltrue([for r in var.cors_rules : length(r.allowed_origins) > 0])
    error_message = "every CORS rule must name at least one allowed origin."
  }
}

variable "tags" {
  description = "Tags for the bucket and the created KMS key, on top of any provider default_tags."
  type        = map(string)
  default     = {}
}
