locals {
  # Full repository names, keyed the same way as var.repositories so every reference below and
  # every output stays on the consumer's short domain keys.
  repository_names = {
    for key, repo in var.repositories : key => var.name_prefix == "" ? key : "${var.name_prefix}/${key}"
  }

  # Per-repository tags: the module-wide tags first, then the repository's own, so the more
  # specific value wins. An empty result is passed to the provider as null rather than {}, which
  # is how a repository that never set tags is stored; setting {} explicitly would plan a change
  # on adoption.
  repository_tags = {
    for key, repo in var.repositories : key => merge(var.tags, repo.tags)
  }

  # Only repositories the module generates a policy for. One with an explicit lifecycle_policy is
  # written verbatim instead, and both land in local.lifecycle_policies below.
  #
  # Rule order is the contract: ECR applies the lowest rulePriority first. Rule 1 sweeps untagged
  # images by age, rule 2 keeps the newest N images carrying one of the tag prefixes. A rule whose
  # tagStatus is "tagged" must carry a tagPrefixList or a tagPatternList, and one whose tagStatus
  # is "untagged" must carry neither, which is why the two rules are shaped differently.
  generated_lifecycle_policies = {
    for key, repo in var.repositories : key => jsonencode({
      rules = [
        {
          rulePriority = 1
          description  = "Expire untagged images after ${coalesce(repo.expire_untagged_after_days, var.expire_untagged_after_days)} ${coalesce(repo.expire_untagged_after_days, var.expire_untagged_after_days) == 1 ? "day" : "days"}"
          selection = {
            tagStatus   = "untagged"
            countType   = "sinceImagePushed"
            countUnit   = "days"
            countNumber = coalesce(repo.expire_untagged_after_days, var.expire_untagged_after_days)
          }
          action = { type = "expire" }
        },
        {
          rulePriority = 2
          description  = "Keep the last ${coalesce(repo.keep_last_tagged_images, var.keep_last_tagged_images)} tagged ${coalesce(repo.keep_last_tagged_images, var.keep_last_tagged_images) == 1 ? "image" : "images"}"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = coalesce(repo.tag_prefix_list, var.tag_prefix_list)
            countType     = "imageCountMoreThan"
            countNumber   = coalesce(repo.keep_last_tagged_images, var.keep_last_tagged_images)
          }
          action = { type = "expire" }
        },
      ]
    })
  }

  # The policy each repository actually gets: an explicit one wins over the generated pair.
  lifecycle_policies = var.create_lifecycle_policy ? {
    for key, repo in var.repositories : key => coalesce(repo.lifecycle_policy, local.generated_lifecycle_policies[key])
  } : {}

  # A repository policy is written only when the consumer asked for one. Same-account Lambda pulls
  # need none, so the default is no aws_ecr_repository_policy resource at all rather than an empty
  # policy document.
  create_repository_policy = var.repository_policy_json != null || length(var.repository_policy_principals) > 0

  repository_policy_keys = local.create_repository_policy ? var.repositories : {}

  # Refuse at plan time the one combination where the module would have to pick a winner.
  validate_policy_inputs = var.repository_policy_json != null && length(var.repository_policy_principals) > 0 ? tobool("Set repository_policy_json or repository_policy_principals, not both: repository_policy_json already replaces the generated policy.") : true
}
