variable "role_name" {
  description = "Full name of the IAM role GitHub Actions assumes, for example carmodpicker-production-github-actions-deploy. It is the name as-is, not a prefix; a rename replaces the role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be 1 to 64 characters of letters, digits and the characters + = , . @ _ -."
  }
}

variable "role_path" {
  description = "IAM path of the role. Changing it replaces the role."
  type        = string
  default     = "/"

  validation {
    condition     = startswith(var.role_path, "/") && endswith(var.role_path, "/")
    error_message = "role_path must start and end with a slash, for example / or /deploy/."
  }
}

variable "role_description" {
  description = "Description shown on the IAM role. Leave null for none."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds for the role. GitHub's aws-actions/configure-aws-credentials asks for 3600 unless told otherwise."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional ARN of a permissions boundary policy to set on the role."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to the role and, when created here, the OIDC provider, on top of the provider's default_tags. Leave empty to rely on default_tags alone, which is what an estate that never set resource tags explicitly does today."
  type        = map(string)
  default     = {}
}

variable "subjects" {
  description = "GitHub OIDC subject claims allowed to assume the role, matched with StringLike, so * and ? are wildcards. Each is a full repo:ORG/REPO:... string: repo:WebbPulse/CarModPicker:* admits every workflow in the repository, repo:WebbPulse/CarModPicker:environment:production only jobs bound to that environment, repo:WebbPulse/CarModPicker:ref:refs/heads/main only pushes to main. GitHub also accepts the rename-proof form repo:ORG@ORG_ID/REPO@REPO_ID:*."
  type        = list(string)

  validation {
    condition     = length(var.subjects) > 0
    error_message = "subjects must list at least one subject claim; an empty list is a role nobody can assume."
  }

  validation {
    condition     = alltrue([for s in var.subjects : startswith(s, "repo:") && length(split(":", s)) >= 3])
    error_message = "Every subject must look like repo:ORG/REPO:<claim or *>, for example repo:WebbPulse/CarModPicker:*."
  }

  validation {
    condition     = length(distinct(var.subjects)) == length(var.subjects)
    error_message = "subjects contains a duplicate entry."
  }
}

variable "audience" {
  description = "Audience (aud) claim the trust policy requires and, when the OIDC provider is created here, its client id. aws-actions/configure-aws-credentials requests sts.amazonaws.com."
  type        = string
  default     = "sts.amazonaws.com"

  validation {
    condition     = length(var.audience) > 0
    error_message = "audience must not be empty."
  }
}

variable "create_oidc_provider" {
  description = "Create the account-level IAM OIDC provider for token.actions.githubusercontent.com. An account has at most one provider per URL, so set this to false in the second stack that needs it within the same account and pass oidc_provider_arn instead."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of an existing token.actions.githubusercontent.com OIDC provider, used as the trust policy principal when create_oidc_provider is false. Ignored when the provider is created here."
  type        = string
  default     = null

  validation {
    condition     = var.create_oidc_provider || var.oidc_provider_arn != null
    error_message = "oidc_provider_arn must be set when create_oidc_provider is false."
  }

  validation {
    condition     = var.oidc_provider_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must look like arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com."
  }
}

variable "oidc_thumbprints" {
  description = "Server certificate thumbprints on the created OIDC provider. AWS verifies GitHub's tokens against its own trusted CA store since 2023, so these are informational, but the resource still requires the list and changing it updates the provider in place. The default is the pair both estates were created with."
  type        = list(string)
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  validation {
    condition     = length(var.oidc_thumbprints) >= 1 && length(var.oidc_thumbprints) <= 5 && alltrue([for t in var.oidc_thumbprints : can(regex("^[0-9a-f]{40}$", t))])
    error_message = "oidc_thumbprints must hold 1 to 5 lowercase 40-character hexadecimal SHA-1 thumbprints."
  }
}

variable "inline_policy_name" {
  description = "Name of the single inline policy that carries policy_statements."
  type        = string
  default     = "deploy-permissions"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", var.inline_policy_name))
    error_message = "inline_policy_name must be 1 to 128 characters of letters, digits and the characters + = , . @ _ -."
  }
}

variable "policy_statements" {
  description = "Statements of the inline deploy policy, one object per IAM statement: actions and resources are required, effect defaults to Allow, sid and condition are optional. condition is operator -> key -> values, for example { StringEquals = { \"aws:ResourceTag/Project\" = [\"x\"] } }. An empty list creates no inline policy, for roles whose permissions are attached from outside using role_name."
  type = list(object({
    sid       = optional(string)
    effect    = optional(string, "Allow")
    actions   = list(string)
    resources = list(string)
    condition = optional(map(map(list(string))))
  }))
  default = []

  validation {
    condition     = alltrue([for s in var.policy_statements : contains(["Allow", "Deny"], s.effect)])
    error_message = "Every statement's effect must be Allow or Deny."
  }

  validation {
    condition     = alltrue([for s in var.policy_statements : length(s.actions) > 0 && length(s.resources) > 0])
    error_message = "Every statement needs at least one action and at least one resource. Use \"*\" as the resource for actions that do not support resource-level permissions."
  }

  validation {
    condition     = alltrue([for s in var.policy_statements : s.condition == null || alltrue([for op, kv in coalesce(s.condition, {}) : length(kv) > 0 && alltrue([for k, v in kv : length(v) > 0])])])
    error_message = "Every condition operator needs at least one key, and every key at least one value."
  }

  validation {
    condition     = length(distinct(compact([for s in var.policy_statements : coalesce(s.sid, "")]))) == length(compact([for s in var.policy_statements : coalesce(s.sid, "")]))
    error_message = "Statement sids must be unique within the policy."
  }
}
