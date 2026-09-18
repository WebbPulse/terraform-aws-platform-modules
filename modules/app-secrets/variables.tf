variable "name_prefix" {
  description = "String put in front of every secret's key to form its Secrets Manager name, joined with name_separator. Typically the estate prefix, for example carmodpicker-staging, which gives names like carmodpicker-staging/secret-key. Leave empty to use each key's name as the full secret name."
  type        = string
  default     = ""

  validation {
    condition     = !endswith(var.name_prefix, "/")
    error_message = "name_prefix must not end with a separator; name_separator supplies it."
  }
}

variable "name_separator" {
  description = "Character joining name_prefix to a secret's name. Secrets Manager allows / _ + = . @ - in a name, and a slash is the usual path-like convention."
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^[/_+=.@-]$", var.name_separator))
    error_message = "name_separator must be a single one of the characters / _ + = . @ - which are what Secrets Manager accepts in a name."
  }
}

variable "recovery_window_in_days" {
  description = "Default recovery window applied to every secret that does not set its own. 0 deletes a secret immediately on destroy, which is what a rebuildable application secret wants; 7 to 30 keeps it recoverable. A secret whose name is reused soon after a destroy needs 0, because Secrets Manager refuses to reuse the name of a secret still scheduled for deletion."
  type        = number
  default     = 0

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "kms_key_id" {
  description = "Default KMS key (id, alias or ARN) encrypting every secret that does not set its own. Leave null to use the account's aws/secretsmanager managed key, which is what an estate that never chose a key has today. Changing this on an existing secret re-encrypts it in place."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every secret, on top of the provider's default_tags. Per-secret tags in the secrets map are merged over these. Leave empty to rely on default_tags alone, which is what an estate that never set resource tags explicitly does today."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = <<-EOT
    The secrets to manage, keyed by a short name. The key becomes the secret's name after name_prefix,
    unless `name` overrides it outright.

    Exactly one source of the stored value per secret, or none at all:

    - `generate`   : a password generated here by an ephemeral random_password and written straight to
                     Secrets Manager. The value never enters state or plan output, and the module
                     never reads it back. Because an ephemeral value is regenerated on every run, the
                     write happens only when `version` changes, so bumping `version` rotates every
                     generated entry in that secret.
    - `value`      : a value the caller passes in, typically from a sensitive Terraform variable. It is
                     written through the write-only argument, so bump `version` to publish a change.
    - `json`       : a map composed into one JSON object and stored as the secret string. Use it for the
                     single blob an application reads at cold start. Entries whose value is null are
                     dropped; an empty string is kept, because an application that distinguishes
                     "set to empty" from "absent" needs the key present. It is written through the
                     write-only argument, so bump `version` to publish a change.
    - `json_generate`: generated keys added to the same blob as `json`, so a value the application
                     needs alongside its other settings does not cost a second secret. Each entry
                     picks a `format`: `password` for a random_password character string, or
                     `bytes32-base64` for 32 raw random bytes in standard base64. A generated entry is
                     minted fresh on every write of the blob, so set `keep = true` once its value is
                     live and the module reads the current version back and writes the same value
                     through again, leaving it alone while other keys change. That read fails if the
                     secret has no version yet, so a first apply in a fresh account passes
                     json_generate_carry_enabled = false rather than editing `keep`.
    - `placeholder`: a literal seeded once, with `ignore_changes` on the value, so an operator can set
                     the real value out of band with `aws secretsmanager put-secret-value` and Terraform
                     will not revert it. This is the shape for a value Terraform must never learn.
    - none of them : the secret is created empty and Terraform manages no version at all. An operator
                     populates it entirely out of band. `create_empty_version` decides whether the
                     resource for the version exists, so this is also the shape for a secret whose
                     value is optional.

    Other per-secret fields:

    - `description`             : shown in the console; defaults to description_default.
    - `version`                 : counter behind the write-only argument. Terraform writes the value
                                  only when this number changes, because it cannot compare a value it
                                  never keeps. Bump it to rewrite the value or to rotate generated
                                  entries.
    - `recovery_window_in_days` : overrides the module default for this secret.
    - `kms_key_id`              : overrides the module default for this secret.
    - `tags`                    : merged over the module-wide tags.
    - `generate_length`,
      `generate_special`,
      `generate_override_special`,
      `generate_min_special`,
      `generate_min_numeric`,
      `generate_min_upper`,
      `generate_min_lower`     : passed to random_password when `generate` is true, defaulting to
                                 the provider's own defaults.
  EOT

  type = map(object({
    name        = optional(string)
    description = optional(string)
    version     = optional(number, 1)

    generate                  = optional(bool, false)
    generate_length           = optional(number, 32)
    generate_special          = optional(bool, true)
    generate_override_special = optional(string)
    generate_min_special      = optional(number, 0)
    generate_min_numeric      = optional(number, 0)
    generate_min_upper        = optional(number, 0)
    generate_min_lower        = optional(number, 0)

    value = optional(string)
    json  = optional(map(string))
    json_generate = optional(map(object({
      format = optional(string, "password")
      keep   = optional(bool, false)

      length           = optional(number, 32)
      special          = optional(bool, true)
      override_special = optional(string)
      min_special      = optional(number, 0)
      min_numeric      = optional(number, 0)
      min_upper        = optional(number, 0)
      min_lower        = optional(number, 0)
    })), {})
    placeholder = optional(string)

    recovery_window_in_days = optional(number)
    kms_key_id              = optional(string)
    tags                    = optional(map(string), {})
  }))

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      length([for present in [s.generate, s.value != null, s.json != null || length(s.json_generate) > 0, s.placeholder != null] : present if present]) <= 1
    ])
    error_message = "Each secret sets at most one of generate, value, the json pair and placeholder. json and json_generate go together, because json_generate adds generated keys to the same blob. A secret that sets none is created empty and Terraform manages no version for it."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      alltrue([for g in values(s.json_generate) : contains(["password", "bytes32-base64"], g.format)])
    ])
    error_message = "A json_generate entry's format must be password or bytes32-base64. password is a random_password character string; bytes32-base64 is 32 raw random bytes in standard base64, which is the shape a key derivation function or an HMAC key wants."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      length(setintersection(keys(coalesce(s.json, {})), keys(s.json_generate))) == 0
    ])
    error_message = "A key cannot appear in both json and json_generate on the same secret. Each key in the blob is either passed in or generated, never both."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      alltrue([for g in values(s.json_generate) : g.format != "password" || (g.length >= 8 && g.length <= 512)])
    ])
    error_message = "A password json_generate entry's length must be between 8 and 512. Anything shorter than 8 is not worth generating."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      alltrue([for g in values(s.json_generate) : g.format != "password" || (g.min_special + g.min_numeric + g.min_upper + g.min_lower) <= g.length])
    ])
    error_message = "The min_* floors of a json_generate entry cannot add up to more than its length."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      can(regex("^[A-Za-z0-9/_+=.@-]{1,512}$", coalesce(s.name, k)))
    ])
    error_message = "A secret's name, or its map key when name is unset, must be 1 to 512 characters of letters, digits and the characters / _ + = . @ - which are what Secrets Manager accepts."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      s.recovery_window_in_days == null || s.recovery_window_in_days == 0 || (coalesce(s.recovery_window_in_days, 0) >= 7 && coalesce(s.recovery_window_in_days, 0) <= 30)
    ])
    error_message = "A secret's recovery_window_in_days must be 0 or between 7 and 30."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      !s.generate || (s.generate_length >= 8 && s.generate_length <= 512)
    ])
    error_message = "generate_length must be between 8 and 512. Anything shorter than 8 is not worth generating."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      !s.generate || (s.generate_min_special + s.generate_min_numeric + s.generate_min_upper + s.generate_min_lower) <= s.generate_length
    ])
    error_message = "The generate_min_* floors of a secret cannot add up to more than its generate_length."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      s.json == null || length(s.json) > 0
    ])
    error_message = "A secret's json map must hold at least one key. Omit json entirely for a secret with no Terraform-managed value."
  }

  validation {
    condition = alltrue([
      for k, s in var.secrets :
      s.version >= 1 && floor(s.version) == s.version
    ])
    error_message = "A secret's version must be a whole number of 1 or more. It is the counter the write-only argument compares against, and Secrets Manager is written only when it changes."
  }
}

variable "json_generate_carry_enabled" {
  description = <<-EOT
    Plan time known switch for whether a kept json_generate entry is read back from the secret's
    current version. True, the default, is the historic behaviour, so a consumer that does not set
    this sees no plan change at all.

    Set it to a literal false on the first apply in a fresh account. A kept entry makes the module
    read the secret's current version through an ephemeral aws_secretsmanager_secret_version, and
    that read fails when the secret has no version yet: the same apply that creates the secret also
    reads it, and the run stops with "reading AWS Secrets Manager Secret Versions Data Source
    (<null>): couldn't find resource" after most of the estate has already been created. Whether a
    version exists is not knowable at plan time, so it has to come in as a boolean the consumer
    already knows, typically the same switch that gates the function images, for example
    bootstrap_image_tag != "".

    False mints every kept entry fresh, exactly as keep = false does, does not declare the ephemeral
    read at all, and still writes the version. Pass true from the second apply onwards and the kept
    entries are carried forward again.
  EOT

  type    = bool
  default = true
}

variable "create_empty_version" {
  description = "Whether a secret that sets none of generate, value, json and placeholder still gets an aws_secretsmanager_secret_version resource, holding an empty string. Off by default, which is what a secret populated entirely out of band wants: the secret exists and the application's IAM grant is in place, and the first put-secret-value creates the first version."
  type        = bool
  default     = false
}

variable "description_default" {
  description = "Description put on any secret that does not set its own. Leave null for no description."
  type        = string
  default     = null
}

variable "policy_sid" {
  description = "Sid on the statement of the generated read policy. Leave null to render the statement without a Sid, which is what a hand-written policy that never set one has in state."
  type        = string
  default     = null

  validation {
    condition     = var.policy_sid == null || can(regex("^[A-Za-z0-9]{1,100}$", var.policy_sid))
    error_message = "policy_sid must be 1 to 100 alphanumeric characters; IAM rejects anything else in a Sid."
  }
}

variable "policy_actions" {
  description = "Actions in the generated read policy. The default is the pair an application needs to read a secret at cold start and check its metadata. Trim it to secretsmanager:GetSecretValue alone to match a policy already in state that grants only that."
  type        = list(string)
  default     = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]

  validation {
    condition     = length(var.policy_actions) > 0
    error_message = "policy_actions must list at least one action."
  }

  validation {
    condition     = alltrue([for a in var.policy_actions : startswith(a, "secretsmanager:")])
    error_message = "policy_actions must only hold secretsmanager: actions. This module's policy grants access to its own secrets and nothing else."
  }
}

variable "policy_secret_keys" {
  description = "Keys of the secrets the generated read policy covers. Leave null for every secret the module manages, which is the usual case. Name a subset when one role should read only some of them, and take a second policy from a second instance of the module or build it by hand from the arns output."
  type        = list(string)
  default     = null
}
