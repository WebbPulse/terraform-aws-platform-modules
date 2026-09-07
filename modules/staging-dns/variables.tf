variable "enabled" {
  description = "Create the hosted zone (and, with delegate, the NS delegation). false makes the module a no-op, which is how a production workspace that serves the apex from a zone owned elsewhere consumes it. Every resource in the module is count-gated on this flag."
  type        = bool
  default     = true
}

variable "zone_name" {
  description = "Fully qualified name of the hosted zone to create, for example staging.example.com. No trailing dot; it is passed to aws_route53_zone.name verbatim so an adopted zone keeps its exact stored name."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.zone_name))
    error_message = "zone_name must be a lowercase DNS name of at least two labels without a trailing dot, for example staging.example.com."
  }
}

variable "delegate" {
  description = "Write an NS record for zone_name into parent_zone_id through the aws.parent provider so resolvers reach the new zone. false creates an undelegated zone: the apex itself, where the registrar holds the NS records, or a zone that is delegated by hand."
  type        = bool
  default     = true
}

variable "parent_zone_id" {
  description = "Hosted zone id of the parent of zone_name, owned by the account aws.parent authenticates to. Required when enabled and delegate are both true; ignored otherwise, so a consumer can pass the same variable in every environment."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !(var.enabled && var.delegate) || (var.parent_zone_id != null && var.parent_zone_id != "")
    error_message = "parent_zone_id must be set when enabled and delegate are both true: the NS delegation for zone_name is written into that zone. Set delegate = false to create a zone that is not delegated by this module."
  }
}

variable "delegation_ttl" {
  description = "TTL in seconds of the NS delegation record in the parent zone."
  type        = number
  default     = 300

  validation {
    condition     = var.delegation_ttl >= 1 && var.delegation_ttl <= 2147483647 && floor(var.delegation_ttl) == var.delegation_ttl
    error_message = "delegation_ttl must be a whole number of seconds between 1 and 2147483647."
  }
}

variable "comment" {
  description = "Comment stored on the hosted zone. null leaves it to the AWS provider, which writes \"Managed by Terraform\"; that is what an adopted zone created without a comment already carries."
  type        = string
  default     = null
  nullable    = true
}

variable "force_destroy" {
  description = "Delete every record in the zone when the zone is destroyed. Off by default so destroying the module never silently removes records added outside Terraform."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to add to the hosted zone on top of the provider default_tags. Leave empty when the consumer already tags through default_tags; an empty map is passed as null so it plans identically to a zone that never set tags."
  type        = map(string)
  default     = {}
}
