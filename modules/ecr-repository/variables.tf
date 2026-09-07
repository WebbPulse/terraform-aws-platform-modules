variable "name_prefix" {
  description = "Prefix put in front of every key in repositories to build the ECR repository name, joined with a slash, \"<name_prefix>/<key>\". Usually \"<project>-<environment>\", for example carmodpicker-production. A slash reads as a namespace and the console groups on it, so one environment's domain repositories sort together. Leave it empty to use each key as the repository name verbatim."
  type        = string
  default     = ""

  validation {
    condition     = !endswith(var.name_prefix, "/")
    error_message = "name_prefix must not end with a slash: the module already joins it to the repository key with one."
  }

  validation {
    condition     = var.name_prefix == "" || can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits, and single periods, underscores or hyphens between them, which is what ECR allows in a repository name component."
  }
}

variable "repositories" {
  description = <<-EOT
    The repositories to create, keyed by the short domain name that follows name_prefix. One
    repository per domain function per environment, so a lifecycle rule that says "keep the last
    10 tagged images" means the last 10 builds of that domain. Every field is optional and null
    takes the module-wide input of the same name:

      image_tag_mutability        per-repository override of var.image_tag_mutability.
      scan_on_push                per-repository override of var.scan_on_push.
      keep_last_tagged_images     per-repository override of var.keep_last_tagged_images.
      expire_untagged_after_days  per-repository override of var.expire_untagged_after_days.
      tag_prefix_list             per-repository override of var.tag_prefix_list.
      lifecycle_policy            a complete lifecycle policy JSON document. When set, the module
                                  writes it verbatim and ignores every generated-rule input above
                                  for this repository. The escape hatch for a policy the two
                                  generated rules cannot express.
      force_delete                per-repository override of var.force_delete.
      tags                        extra tags for this repository on top of tags and the provider
                                  default_tags.

    An empty object, {}, is the normal entry: it takes every module-wide default.
  EOT

  type = map(object({
    image_tag_mutability       = optional(string)
    scan_on_push               = optional(bool)
    keep_last_tagged_images    = optional(number)
    expire_untagged_after_days = optional(number)
    tag_prefix_list            = optional(list(string))
    lifecycle_policy           = optional(string)
    force_delete               = optional(bool)
    tags                       = optional(map(string), {})
  }))

  validation {
    condition = alltrue([
      for k in keys(var.repositories) : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", k))
    ])
    error_message = "Repository keys must be lowercase letters and digits, with single periods, underscores, hyphens or slashes between them. That is the ECR repository name grammar, and the key becomes the part of the name after name_prefix."
  }

  validation {
    condition = alltrue([
      for k, r in var.repositories : length("${var.name_prefix == "" ? "" : "${var.name_prefix}/"}${k}") <= 256
    ])
    error_message = "Each full repository name, \"<name_prefix>/<key>\", must be 256 characters or fewer."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : r.image_tag_mutability == null || contains(["MUTABLE", "IMMUTABLE"], coalesce(r.image_tag_mutability, "IMMUTABLE"))
    ])
    error_message = "A repository's image_tag_mutability override must be MUTABLE or IMMUTABLE."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : r.keep_last_tagged_images == null || (coalesce(r.keep_last_tagged_images, 1) >= 1 && floor(coalesce(r.keep_last_tagged_images, 1)) == coalesce(r.keep_last_tagged_images, 1))
    ])
    error_message = "A repository's keep_last_tagged_images override must be a whole number of at least 1. ECR rejects a countNumber of 0."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : r.expire_untagged_after_days == null || (coalesce(r.expire_untagged_after_days, 1) >= 1 && floor(coalesce(r.expire_untagged_after_days, 1)) == coalesce(r.expire_untagged_after_days, 1))
    ])
    error_message = "A repository's expire_untagged_after_days override must be a whole number of at least 1. ECR rejects a countNumber of 0."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : r.tag_prefix_list == null || length(coalesce(r.tag_prefix_list, [])) > 0
    ])
    error_message = "A repository's tag_prefix_list override must hold at least one prefix. ECR requires a tagPrefixList or a tagPatternList on a rule whose tagStatus is tagged; pass null to take the module-wide value instead of an empty list."
  }
}

variable "image_tag_mutability" {
  description = "Module-wide tag mutability: IMMUTABLE refuses a push that would move an existing tag, MUTABLE allows it. IMMUTABLE is the default and the shape this module is built for, because a commit-SHA tag that cannot move is what makes a deploy reproducible and makes the digest Lambda records meaningful. A repository can override it. Note that IMMUTABLE rules out a moving tag such as env-staging in the same repository: mutability is a repository-level setting, not a per-tag one."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Module-wide basic scan on push, which is the free ECR scanner and covers operating system package CVEs. A repository can override it. Enhanced scanning is a different feature: it is Amazon Inspector, it is configured once per registry at the account level rather than per repository, and it bills per scan and per rescan, so it is out of this module's scope."
  type        = bool
  default     = true
}

variable "keep_last_tagged_images" {
  description = "Module-wide count for the \"keep the last N tagged images\" lifecycle rule: ECR expires tagged images beyond the newest N. A repository can override it. Keep enough headroom that a rule can never expire an image a live function might still scale out onto; below about five is uncomfortable."
  type        = number
  default     = 10

  validation {
    condition     = var.keep_last_tagged_images >= 1 && floor(var.keep_last_tagged_images) == var.keep_last_tagged_images
    error_message = "keep_last_tagged_images must be a whole number of at least 1. ECR rejects a countNumber of 0."
  }
}

variable "expire_untagged_after_days" {
  description = "Module-wide age in days after which an untagged image is expired. Untagged images are the ones that accumulate silently, so this is the rule that keeps cost at rest flat. A repository can override it."
  type        = number
  default     = 1

  validation {
    condition     = var.expire_untagged_after_days >= 1 && floor(var.expire_untagged_after_days) == var.expire_untagged_after_days
    error_message = "expire_untagged_after_days must be a whole number of at least 1. ECR rejects a countNumber of 0."
  }
}

variable "tag_prefix_list" {
  description = "Module-wide list of tag prefixes the \"keep the last N tagged images\" rule selects on, written into the rule as tagPrefixList. The default matches the sha-<commit> tags this estate pushes. ECR requires a tagPrefixList or a tagPatternList on a rule whose tagStatus is tagged; a tagged image matching no prefix here is never expired by that rule, so the list must cover every tag scheme in the repository. A repository can override it."
  type        = list(string)
  default     = ["sha-"]

  validation {
    condition     = length(var.tag_prefix_list) > 0
    error_message = "tag_prefix_list must hold at least one prefix. ECR requires a tagPrefixList or a tagPatternList on a rule whose tagStatus is tagged."
  }

  validation {
    condition     = alltrue([for p in var.tag_prefix_list : length(p) > 0])
    error_message = "tag_prefix_list entries must not be empty strings."
  }
}

variable "create_lifecycle_policy" {
  description = "Create the lifecycle policy at all. false leaves every repository without one, which means nothing is ever expired and storage grows with every push. It exists so a repository can be adopted before its policy is, not as a setting to leave off."
  type        = bool
  default     = true
}

variable "encryption_type" {
  description = "Module-wide encryption at rest: AES256 is the ECR managed key and costs nothing per request, KMS uses a KMS key and adds a KMS request charge on top of every layer upload and pull. AES256 is the default because KMS buys nothing here that AES256 does not already give. Set KMS with encryption_kms_key when a compliance rule asks for a customer managed key."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "KMS", "KMS_DSSE"], var.encryption_type)
    error_message = "encryption_type must be AES256, KMS or KMS_DSSE."
  }
}

variable "encryption_kms_key" {
  description = "KMS key ARN for the encryption configuration, only meaningful when encryption_type is KMS or KMS_DSSE. null lets ECR use the AWS managed aws/ecr key for the account. Encryption is fixed when the repository is created, so changing either encryption input replaces every repository."
  type        = string
  default     = null

  validation {
    condition     = var.encryption_kms_key == null || var.encryption_type != "AES256"
    error_message = "encryption_kms_key belongs to a KMS or KMS_DSSE encryption_type: set encryption_type as well, or leave the key null."
  }
}

variable "force_delete" {
  description = "Module-wide switch letting Terraform delete a repository that still holds images. false means a destroy fails until the images are removed on purpose, which is the safe default for anything a Lambda pulls from. A repository can override it."
  type        = bool
  default     = false
}

variable "repository_policy_principals" {
  description = <<-EOT
    Principals allowed to pull images, written into a repository policy. Empty creates no policy at
    all, which is the right answer for the same-account Lambda case: same-account access needs only
    one side to allow it, and Lambda adds the retrieval statement to the repository itself when the
    function is created. See the README section on Lambda and repository policies.

    This exists for cross-account pulls, where AWS requires both sides to allow the action. Entries
    are IAM principal ARNs, for example an account root "arn:aws:iam::123456789012:root". The module
    writes one statement granting ecr:BatchGetImage, ecr:GetDownloadUrlForLayer and
    ecr:DescribeImages, plus a second statement letting lambda.amazonaws.com retrieve the image on
    behalf of a function in one of those accounts, which is what a cross-account container-image
    Lambda needs to survive re-optimisation.
  EOT

  type    = list(string)
  default = []

  validation {
    condition     = alltrue([for p in var.repository_policy_principals : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|user/.+|role/.+)$", p))])
    error_message = "Every repository_policy_principals entry must be an IAM principal ARN: an account root, a user, or a role."
  }

  validation {
    condition     = length(var.repository_policy_principals) == length(distinct(var.repository_policy_principals))
    error_message = "repository_policy_principals must not repeat a principal."
  }
}

variable "repository_policy_json" {
  description = "A complete repository policy JSON document, applied to every repository, replacing the one the module would build from repository_policy_principals. The escape hatch for a policy the generated statements cannot express. Setting both this and repository_policy_principals is refused, because only one of them can win."
  type        = string
  default     = null

  validation {
    condition     = var.repository_policy_json == null || can(jsondecode(var.repository_policy_json))
    error_message = "repository_policy_json must be valid JSON."
  }
}

variable "tags" {
  description = "Tags applied to every repository on top of the provider default_tags. Empty is passed to the provider as null so it plans identically to a repository that never set tags."
  type        = map(string)
  default     = {}
}
