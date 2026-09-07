variable "name_prefix" {
  description = "Prefix put in front of every key in tables to build the DynamoDB table name, joined with a hyphen, \"<name_prefix>-<key>\". Usually local.prefix, for example carmodpicker-staging. Leave it empty to use each key as the table name verbatim."
  type        = string
  default     = ""

  validation {
    condition     = !endswith(var.name_prefix, "-")
    error_message = "name_prefix must not end with a hyphen: the module already joins it to the table key with one."
  }
}

variable "tables" {
  description = <<-EOT
    The tables to create, keyed by the short name that follows name_prefix. Each value describes
    one table:

      attributes  list of { name, type } for every key attribute the table or its indexes use.
                  type is S, N or B. DynamoDB rejects an attribute that no key references, and
                  requires one for every key, so this list is exactly the key attributes.
      hash_key    partition key attribute name; must appear in attributes.
      range_key   sort key attribute name, or null for a table keyed only by its partition key.
      global_secondary_indexes  list of { name, hash_key, range_key, projection_type,
                  non_key_attributes, read_capacity, write_capacity }. Only name and hash_key are
                  required; the rest default to null, and projection_type defaults to ALL.
      ttl_attribute  attribute holding the expiry epoch seconds, or null for no TTL.
      point_in_time_recovery  per-table override of the module-wide point_in_time_recovery
                  input. null takes the module-wide value.
      deletion_protection  per-table override of the module-wide deletion_protection input.
                  null takes the module-wide value.
      tags        extra tags for this table on top of tags and the provider default_tags.

    Every field except attributes and hash_key is optional.
  EOT

  type = map(object({
    attributes = list(object({
      name = string
      type = string
    }))
    hash_key  = string
    range_key = optional(string)
    global_secondary_indexes = optional(list(object({
      name               = string
      hash_key           = string
      range_key          = optional(string)
      projection_type    = optional(string, "ALL")
      non_key_attributes = optional(list(string))
      read_capacity      = optional(number)
      write_capacity     = optional(number)
    })), [])
    ttl_attribute          = optional(string)
    point_in_time_recovery = optional(bool)
    deletion_protection    = optional(bool)
    tags                   = optional(map(string), {})
  }))

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([for a in t.attributes : contains(["S", "N", "B"], a.type)])
    ])
    error_message = "Every attribute type must be S (string), N (number) or B (binary)."
  }

  validation {
    condition = alltrue([
      for t in var.tables : length(t.attributes) == length(distinct([for a in t.attributes : a.name]))
    ])
    error_message = "Attribute names must be unique within a table."
  }

  validation {
    condition = alltrue([
      for t in var.tables : contains([for a in t.attributes : a.name], t.hash_key)
    ])
    error_message = "Each table's hash_key must name one of that table's attributes."
  }

  validation {
    condition = alltrue([
      for t in var.tables : t.range_key == null || contains([for a in t.attributes : a.name], t.range_key)
    ])
    error_message = "A table's range_key, when set, must name one of that table's attributes."
  }

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([
        for g in t.global_secondary_indexes : contains([for a in t.attributes : a.name], g.hash_key)
        && (g.range_key == null || contains([for a in t.attributes : a.name], g.range_key))
      ])
    ])
    error_message = "Every global secondary index hash_key and range_key must name one of the same table's attributes. DynamoDB rejects an index key that has no attribute definition."
  }

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([
        for g in t.global_secondary_indexes : contains(["ALL", "KEYS_ONLY", "INCLUDE"], g.projection_type)
      ])
    ])
    error_message = "Every global secondary index projection_type must be ALL, KEYS_ONLY or INCLUDE."
  }

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([
        for g in t.global_secondary_indexes :
        (g.projection_type == "INCLUDE") == (g.non_key_attributes != null && length(coalesce(g.non_key_attributes, [])) > 0)
      ])
    ])
    error_message = "non_key_attributes belongs to a projection_type of INCLUDE and only to that: set both together, or neither."
  }

  validation {
    condition = alltrue([
      for t in var.tables : length(t.global_secondary_indexes) == length(distinct([for g in t.global_secondary_indexes : g.name]))
    ])
    error_message = "Global secondary index names must be unique within a table."
  }

  validation {
    condition = alltrue([
      for k in keys(var.tables) : can(regex("^[A-Za-z0-9_.-]{1,255}$", k))
    ])
    error_message = "Table keys may hold only letters, digits, underscores, hyphens and dots, which is what DynamoDB allows in a table name."
  }
}

variable "point_in_time_recovery" {
  description = "Module-wide default for continuous backups. A table whose point_in_time_recovery is null takes this. Consumers usually pass var.environment == \"production\"."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Module-wide default for the DynamoDB deletion protection flag, which makes AWS refuse a DeleteTable call. A table whose deletion_protection is null takes this. Consumers usually pass var.environment == \"production\"."
  type        = bool
  default     = false
}

variable "billing_mode" {
  description = "PAY_PER_REQUEST or PROVISIONED. PROVISIONED needs read_capacity and write_capacity on the table and on every index; the module is written for PAY_PER_REQUEST and that is the default."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "read_capacity" {
  description = "Table read capacity units when billing_mode is PROVISIONED. null under PAY_PER_REQUEST, which is what an adopted on-demand table has in state."
  type        = number
  default     = null
  nullable    = true
}

variable "write_capacity" {
  description = "Table write capacity units when billing_mode is PROVISIONED. null under PAY_PER_REQUEST."
  type        = number
  default     = null
  nullable    = true
}

variable "server_side_encryption" {
  description = "Encrypt at rest with a customer managed or AWS managed KMS key instead of the AWS owned key DynamoDB uses by default. null omits the block entirely, which is what a table that never set it has in state; DynamoDB still encrypts, just with the owned key."
  type = object({
    enabled     = bool
    kms_key_arn = optional(string)
  })
  default  = null
  nullable = true
}

variable "stream_enabled" {
  description = "Turn on the table's DynamoDB stream. false leaves stream_view_type unset, which is what a table without a stream has in state."
  type        = bool
  default     = false
}

variable "stream_view_type" {
  description = "What a stream record carries: KEYS_ONLY, NEW_IMAGE, OLD_IMAGE or NEW_AND_OLD_IMAGES. Required when stream_enabled is true."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.stream_view_type == null || contains(["KEYS_ONLY", "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES"], coalesce(var.stream_view_type, "KEYS_ONLY"))
    error_message = "stream_view_type must be KEYS_ONLY, NEW_IMAGE, OLD_IMAGE or NEW_AND_OLD_IMAGES."
  }

  validation {
    condition     = !var.stream_enabled || var.stream_view_type != null
    error_message = "stream_view_type must be set when stream_enabled is true."
  }
}

variable "name_tag" {
  description = "Add a Name tag equal to the table's full name. CarModPicker's hand-written tables carry one, the Portfolio's do not, so this is a flag rather than a fixed behaviour. It merges under tags and a table's own tags, so either can override it."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every table on top of the provider default_tags. Empty is passed to the provider as null so it plans identically to a table that never set tags."
  type        = map(string)
  default     = {}
}
