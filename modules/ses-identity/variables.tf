variable "configuration_set_name" {
  description = "Name of the SES v2 configuration set every email from this identity is sent through, and the name bounce and complaint metrics are published under."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,64}$", var.configuration_set_name))
    error_message = "configuration_set_name must be 1 to 64 characters of letters, digits, dashes or underscores."
  }
}

variable "domain" {
  description = "Sending domain to verify as a domain identity with Easy DKIM. Null sends from sender_address instead."
  type        = string
  default     = null
  nullable    = true
}

variable "sender_address" {
  description = "Single email address to verify as the sending identity when domain is null. One of domain or sender_address is required."
  type        = string
  default     = null
  nullable    = true
}

variable "dkim_signing_key_length" {
  description = "Easy DKIM key length on the domain identity, RSA_1024_BIT or RSA_2048_BIT."
  type        = string
  default     = "RSA_2048_BIT"

  validation {
    condition     = contains(["RSA_1024_BIT", "RSA_2048_BIT"], var.dkim_signing_key_length)
    error_message = "dkim_signing_key_length must be RSA_1024_BIT or RSA_2048_BIT."
  }
}

variable "mail_from_domain" {
  description = "Custom MAIL FROM subdomain on the domain identity, for example bounce.example.com. Null leaves the SES default MAIL FROM in place."
  type        = string
  default     = null
  nullable    = true
}

variable "behavior_on_mx_failure" {
  description = "What SES does when the MAIL FROM MX record is missing, USE_DEFAULT_VALUE or REJECT_MESSAGE."
  type        = string
  default     = "USE_DEFAULT_VALUE"

  validation {
    condition     = contains(["USE_DEFAULT_VALUE", "REJECT_MESSAGE"], var.behavior_on_mx_failure)
    error_message = "behavior_on_mx_failure must be USE_DEFAULT_VALUE or REJECT_MESSAGE."
  }
}

variable "email_forwarding_enabled" {
  description = "Forward bounces and complaints to the identity's own address. False is correct whenever an event destination or SNS topic already carries them."
  type        = bool
  default     = false
}

variable "set_feedback_attributes" {
  description = "Manage the domain identity's feedback forwarding attribute. False leaves the account default untouched."
  type        = bool
  default     = true
}

variable "reputation_metrics_enabled" {
  description = "Publish per configuration set reputation metrics to CloudWatch."
  type        = bool
  default     = true
}

variable "sending_enabled" {
  description = "Allow sending through this configuration set. False pauses every send that names it."
  type        = bool
  default     = true
}

variable "tls_policy" {
  description = "Delivery TLS policy on the configuration set, REQUIRE or OPTIONAL. Null leaves the delivery options block out entirely."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.tls_policy == null || contains(["REQUIRE", "OPTIONAL"], coalesce(var.tls_policy, "REQUIRE"))
    error_message = "tls_policy must be REQUIRE, OPTIONAL or null."
  }
}

variable "vdm_options_enabled" {
  description = "Write the configuration set's vdm_options block with engagement metrics and optimized shared delivery on. False leaves the block out."
  type        = bool
  default     = false
}

variable "manage_account_vdm_attributes" {
  description = "Manage the account wide Virtual Deliverability Manager attributes. This is account scoped, so exactly one module instance per account and region may set it true."
  type        = bool
  default     = false
}

variable "notification_topic_arn" {
  description = "Existing SNS topic that bounce, complaint and delivery delay events are published to through a configuration set event destination. Null creates no event destination."
  type        = string
  default     = null
  nullable    = true
}

variable "notification_event_types" {
  description = "Event types sent to notification_topic_arn."
  type        = list(string)
  default     = ["BOUNCE", "COMPLAINT", "DELIVERY_DELAY"]
}

variable "event_destination_name" {
  description = "Name of the configuration set event destination created for notification_topic_arn."
  type        = string
  default     = "sns-notifications"
}

variable "create_dkim_records" {
  description = "Write the three Easy DKIM CNAME records into dkim_records_zone_id. Needs a domain identity."
  type        = bool
  default     = false
}

variable "dkim_records_zone_id" {
  description = "Route 53 hosted zone id the DKIM CNAMEs are written into. Required when create_dkim_records is true."
  type        = string
  default     = null
  nullable    = true
}

variable "dkim_record_ttl" {
  description = "TTL on the DKIM CNAME records."
  type        = number
  default     = 1800
}

variable "dmarc_record" {
  description = "DMARC policy string published as a TXT record at _dmarc.<domain>. Null writes no DMARC record. Needs dkim_records_zone_id."
  type        = string
  default     = null
  nullable    = true
}

variable "dmarc_record_ttl" {
  description = "TTL on the DMARC TXT record."
  type        = number
  default     = 1800
}

variable "verified_recipients" {
  description = "Email addresses verified as recipient identities so a sandboxed account can send to them. The list is explicit on purpose: sandbox and production access are handled out of band, and this module never requests either. Leave it empty in an account with production access."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for address in var.verified_recipients : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", address))])
    error_message = "Every verified_recipients entry must be an email address."
  }
}

variable "recipient_tags" {
  description = "Tags on each recipient identity, merged over tags."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags on the configuration set and the sending identity."
  type        = map(string)
  default     = {}
}
