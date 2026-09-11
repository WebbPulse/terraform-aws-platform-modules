locals {
  repository_names = {
    for key, repo in var.repositories : key => var.name_prefix == "" ? key : "${var.name_prefix}/${key}"
  }

  repository_tags = {
    for key, repo in var.repositories : key => merge(var.tags, repo.tags)
  }

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

  lifecycle_policies = var.create_lifecycle_policy ? {
    for key, repo in var.repositories : key => coalesce(repo.lifecycle_policy, local.generated_lifecycle_policies[key])
  } : {}

  create_repository_policy = var.repository_policy_json != null || length(var.repository_policy_principals) > 0

  repository_policy_keys = local.create_repository_policy ? var.repositories : {}

  validate_policy_inputs = var.repository_policy_json != null && length(var.repository_policy_principals) > 0 ? tobool("Set repository_policy_json or repository_policy_principals, not both: repository_policy_json already replaces the generated policy.") : true
}
