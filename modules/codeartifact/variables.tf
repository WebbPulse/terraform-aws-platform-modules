variable "domain" {
  description = "Name of the CodeArtifact domain. Storage is billed once per domain, deduplicated across every repository in it, so an estate wants exactly one. The name only has to be unique within the owning account, which is why every cross-account call also carries the domain owner."
  type        = string

  # CreateDomain's own pattern is [a-z][a-z0-9\-]{0,48}[a-z0-9]: it must start with a letter and
  # end alphanumeric, so a trailing hyphen is rejected by the API. Matching it here rather than
  # allowing one and failing on apply.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,48}[a-z0-9]$", var.domain))
    error_message = "domain must be 2 to 50 characters, start with a lowercase letter, end with a lowercase letter or digit, and hold only lowercase letters, digits and hyphens."
  }
}

variable "encryption_key" {
  description = "ARN or id of a symmetric KMS key encrypting every asset in the domain. Leave null for the AWS managed aws/codeartifact key, which is what an estate that never chose a key wants. CodeArtifact rejects asymmetric keys. The key cannot be changed after the domain is created; a different key means a new domain."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to the domain and every repository, on top of the provider's default_tags. Per-repository tags in the repositories map are merged over these. Leave empty to rely on default_tags alone."
  type        = map(string)
  default     = {}
}

variable "repositories" {
  description = <<-EOT
    The repositories in the domain, keyed by repository name. The key is the name as-is, so a rename
    replaces the repository.

    Per-repository fields:

    - `description`          : shown in the console and the API.
    - `external_connections` : public registries this repository proxies, for example
                               ["public:pypi"] or ["public:npmjs"]. CodeArtifact allows at most one
                               external connection per repository, and a repository with one cannot
                               also have upstreams, so these are the leaf "store" repositories.
    - `upstreams`            : keys of other repositories in this same map, searched in order when a
                               package is not found locally. A request walks the chain until it hits
                               a repository with an external connection or runs out.
    - `tags`                 : merged over the module-wide tags.

    The house layout is a store repository per package format holding the external connection, an
    internal repository per format upstreaming to its store, and optionally one fan-in repository
    upstreaming to the internal ones so CI has a single endpoint per package manager.
  EOT

  type = map(object({
    description          = optional(string)
    external_connections = optional(list(string), [])
    upstreams            = optional(list(string), [])
    tags                 = optional(map(string), {})
  }))

  # CreateRepository's pattern is [A-Za-z0-9][A-Za-z0-9._\-]{1,99}, so the effective minimum is two
  # characters, not one.
  validation {
    condition = alltrue([
      for k, _ in var.repositories : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{1,99}$", k))
    ])
    error_message = "Every repository name must be 2 to 100 characters, start with a letter or digit and hold only letters, digits and the characters . _ - which are what CodeArtifact accepts."
  }

  # CodeArtifact allows at most one external connection per repository. The provider models
  # external_connections as a block with max_items 1, so a longer list is a plan-time error with a
  # message about block counts; catching it here says what the actual rule is.
  validation {
    condition = alltrue([
      for k, r in var.repositories : length(r.external_connections) <= 1
    ])
    error_message = "A repository may have at most one external connection. Give each package format its own store repository, for example pypi-store with public:pypi and npm-store with public:npmjs."
  }

  # The rule that shapes the whole layout: an external connection and upstreams are mutually
  # exclusive on one repository, which is why the store repositories exist at all.
  validation {
    condition = alltrue([
      for k, r in var.repositories : length(r.external_connections) == 0 || length(r.upstreams) == 0
    ])
    error_message = "A repository with an external connection cannot also have upstreams. Put the external connection on its own store repository and have the internal repository upstream to it."
  }

  validation {
    condition = alltrue([
      for k, r in var.repositories :
      alltrue([for c in r.external_connections : can(regex("^public:[a-z0-9-]+$", c))])
    ])
    error_message = "An external connection looks like public:<registry>, for example public:pypi, public:npmjs, public:maven-central or public:nuget-org."
  }

  # An upstream naming a repository outside the map would be created against a repository the module
  # does not manage, and the dependency ordering below would not cover it.
  validation {
    condition = alltrue([
      for k, r in var.repositories :
      alltrue([for u in r.upstreams : contains(keys(var.repositories), u)])
    ])
    error_message = "Every upstream must name another key of the repositories map. This module only wires upstreams between repositories it manages."
  }

  validation {
    condition = alltrue([
      for k, r in var.repositories : !contains(r.upstreams, k)
    ])
    error_message = "A repository cannot list itself as an upstream."
  }

  validation {
    condition = alltrue([
      for k, r in var.repositories : length(distinct(r.upstreams)) == length(r.upstreams)
    ])
    error_message = "A repository's upstreams list contains a duplicate entry."
  }

  # Upstream depth is capped at three levels below, because Terraform has no loop and the ordering
  # is expressed as explicit tiers. Two hops, store -> internal -> fan-in, is the deepest layout the
  # house style uses.
  validation {
    condition = alltrue([
      for k, r in var.repositories :
      alltrue([
        for u in r.upstreams :
        alltrue([
          for u2 in try(var.repositories[u].upstreams, []) :
          length(try(var.repositories[u2].upstreams, [])) == 0
        ])
      ])
    ])
    error_message = "Upstream chains are limited to three tiers, for example shared -> python -> pypi-store. A deeper chain cannot be ordered by this module and is almost certainly a mistake."
  }
}

variable "reader_account_ids" {
  description = "AWS account ids granted read access, through the domain policy on the domain and a policy on every repository. Each account's principals still need matching identity-based permissions in their own account, including sts:GetServiceBearerToken, before they can fetch a token; both sides must allow. Leave empty for a single-account domain, which needs no resource policy at all."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.reader_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every entry of reader_account_ids must be a 12-digit AWS account id."
  }

  validation {
    condition     = length(distinct(var.reader_account_ids)) == length(var.reader_account_ids)
    error_message = "reader_account_ids contains a duplicate entry."
  }
}

variable "reader_principal_arns" {
  description = "Principal ARNs granted read access instead of whole accounts. Naming the CI role ARNs directly rather than an account root keeps an unrelated principal in a consumer account out of the registry, which is the tighter grant and the one to prefer. Combined with reader_account_ids when both are set."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.reader_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|(user|role)/.+)$", a))])
    error_message = "Every entry of reader_principal_arns must be an IAM principal ARN, for example arn:aws:iam::123456789012:role/example-github-actions-deploy."
  }

  validation {
    condition     = length(distinct(var.reader_principal_arns)) == length(var.reader_principal_arns)
    error_message = "reader_principal_arns contains a duplicate entry."
  }
}

variable "publisher_principal_arns" {
  description = "Principal ARNs allowed to publish package versions. The grant only ever lands on internal repositories, never on a repository holding an external connection: publishing into a store repository would let a first-party package shadow the public one it proxies. Leave empty for a domain nobody publishes to from another account."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.publisher_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(root|(user|role)/.+)$", a))])
    error_message = "Every entry of publisher_principal_arns must be an IAM principal ARN, for example arn:aws:iam::123456789012:role/example-package-publisher."
  }

  validation {
    condition     = length(distinct(var.publisher_principal_arns)) == length(var.publisher_principal_arns)
    error_message = "publisher_principal_arns contains a duplicate entry."
  }
}

variable "publisher_repository_keys" {
  description = "Keys of the repositories publishers may write to. Leave null for every repository without an external connection, which is the intended shape. Naming a store repository here is rejected."
  type        = list(string)
  default     = null
}

variable "reader_domain_actions" {
  description = "Actions granted on the domain to readers. GetAuthorizationToken is the one that matters: it is a domain-level action, so a repository policy alone cannot grant it. The rest are what the CodeArtifact user guide's cross-account example grants so a package manager can describe the domain and list its repositories. CreateRepository is deliberately absent; consumers read, they do not create repositories in someone else's domain."
  type        = list(string)
  default = [
    "codeartifact:DescribeDomain",
    "codeartifact:GetAuthorizationToken",
    "codeartifact:GetDomainPermissionsPolicy",
    "codeartifact:ListRepositoriesInDomain",
  ]

  validation {
    condition     = length(var.reader_domain_actions) > 0
    error_message = "reader_domain_actions must list at least one action."
  }

  validation {
    condition     = alltrue([for a in var.reader_domain_actions : startswith(a, "codeartifact:")])
    error_message = "reader_domain_actions must only hold codeartifact: actions."
  }
}

variable "reader_repository_actions" {
  description = "Actions granted on every repository to readers. The default is the set the CodeArtifact user guide lists as what a principal downloading packages needs, plus GetRepositoryEndpoint, which pip and npm call to find the URL to talk to. ReadFromRepository is all-or-nothing per repository: the user guide is explicit that a package ARN cannot narrow it."
  type        = list(string)
  default = [
    "codeartifact:DescribePackageVersion",
    "codeartifact:DescribeRepository",
    "codeartifact:GetPackageVersionAsset",
    "codeartifact:GetPackageVersionReadme",
    "codeartifact:GetRepositoryEndpoint",
    "codeartifact:ListPackageVersionAssets",
    "codeartifact:ListPackageVersionDependencies",
    "codeartifact:ListPackageVersions",
    "codeartifact:ListPackages",
    "codeartifact:ReadFromRepository",
  ]

  validation {
    condition     = length(var.reader_repository_actions) > 0
    error_message = "reader_repository_actions must list at least one action."
  }

  validation {
    condition     = alltrue([for a in var.reader_repository_actions : startswith(a, "codeartifact:")])
    error_message = "reader_repository_actions must only hold codeartifact: actions."
  }
}

variable "publisher_repository_actions" {
  description = "Actions granted to publishers on the repositories they may write to. PublishPackageVersion creates the version; PutPackageMetadata is what Maven needs and what npm dist-tags go through. ReadFromRepository is included because a publisher that cannot read cannot check whether a version already exists, and NuGet requires it outright."
  type        = list(string)
  default = [
    "codeartifact:PublishPackageVersion",
    "codeartifact:PutPackageMetadata",
    "codeartifact:ReadFromRepository",
  ]

  validation {
    condition     = length(var.publisher_repository_actions) > 0
    error_message = "publisher_repository_actions must list at least one action."
  }

  validation {
    condition     = alltrue([for a in var.publisher_repository_actions : startswith(a, "codeartifact:")])
    error_message = "publisher_repository_actions must only hold codeartifact: actions."
  }
}

variable "domain_policy_sid" {
  description = "Sid on the reader statement of the domain policy. Leave null to render it without a Sid."
  type        = string
  default     = "CrossAccountRead"

  validation {
    condition     = var.domain_policy_sid == null || can(regex("^[A-Za-z0-9]{1,100}$", var.domain_policy_sid))
    error_message = "domain_policy_sid must be 1 to 100 alphanumeric characters; IAM rejects anything else in a Sid."
  }
}

variable "domain_policy_document" {
  description = "A complete domain policy JSON document replacing the one this module builds. Set it when the generated shape does not fit, for example to grant the whole organization with aws:PrincipalOrgID. reader_account_ids and reader_principal_arns are then ignored for the domain policy but still drive the repository policies."
  type        = string
  default     = null
}

variable "endpoint_formats" {
  description = "Package formats to resolve a repository endpoint for, in the endpoints output. Each format is looked up against every repository, so the map holds an entry per repository and format whether or not that repository holds packages of that format; an endpoint URL exists regardless."
  type        = list(string)
  default     = ["pypi", "npm"]

  validation {
    condition     = alltrue([for f in var.endpoint_formats : contains(["cargo", "generic", "maven", "npm", "nuget", "pypi", "ruby", "swift"], f)])
    error_message = "endpoint_formats must hold CodeArtifact package formats: cargo, generic, maven, npm, nuget, pypi, ruby or swift."
  }

  validation {
    condition     = length(distinct(var.endpoint_formats)) == length(var.endpoint_formats)
    error_message = "endpoint_formats contains a duplicate entry."
  }
}
