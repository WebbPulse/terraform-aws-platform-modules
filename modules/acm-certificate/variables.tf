variable "enabled" {
  description = "Issue the certificate and its validation records. False plans nothing at all, for an environment that serves no custom domain."
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "Primary domain the certificate is issued for. It is the certificate's common name and, with subject_alternative_names, decides how many validation records ACM asks for."
  type        = string

  validation {
    condition     = can(regex("^[*][.]", var.domain_name)) || can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a lowercase hostname such as example.com or api.example.com, optionally a wildcard such as *.example.com."
  }
}

variable "subject_alternative_names" {
  description = "Extra domains the certificate also covers. An apex and its wildcard share one validation CNAME but still count as two covered domains, so each gets its own record resource."
  type        = list(string)
  default     = []
}

variable "zone_id" {
  description = "Route 53 hosted zone the DNS validation records are written into, through the aws.records provider. Every covered domain must validate inside this one zone."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = !var.enabled || var.zone_id != null
    error_message = "zone_id must be set when enabled is true: DNS validation cannot complete without somewhere to write the validation records."
  }
}

variable "validation_record_ttl" {
  description = "TTL in seconds on each DNS validation record. Short is right here, the record is written once and read by ACM shortly after."
  type        = number
  default     = 60

  validation {
    condition     = var.validation_record_ttl >= 0 && var.validation_record_ttl <= 2147483647
    error_message = "validation_record_ttl must be between 0 and 2147483647 seconds."
  }
}

variable "allow_overwrite" {
  description = "Let Terraform take over a validation record that already exists in the zone. True matches how a certificate covering an apex and its wildcard writes the same record twice."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for the certificate, merged on top of the provider's default_tags. The validation records are Route 53 records and take no tags."
  type        = map(string)
  default     = {}
}
