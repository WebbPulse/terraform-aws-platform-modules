variables {
  name_prefix = "example-staging"

  repositories = {
    content  = {}
    resume   = {}
    identity = {}
    public   = {}
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "every_repository_gets_a_lifecycle_policy_with_the_two_generated_rules" {
  command = plan

  assert {
    condition     = length(aws_ecr_lifecycle_policy.this) == 4
    error_message = "create_lifecycle_policy defaults to true, so every repository must get its own policy. A repository without one never expires anything and its storage bill grows with every push, forever."
  }

  assert {
    condition     = length(jsondecode(local.lifecycle_policies["content"]).rules) == 2
    error_message = "The generated policy must hold exactly the two rules this estate relies on: expire untagged images by age, and keep only the last N tagged images."
  }

  assert {
    condition     = [for r in jsondecode(local.lifecycle_policies["content"]).rules : r.rulePriority] == [1, 2]
    error_message = "Rule priorities must be 1 then 2 and must be distinct. ECR evaluates rules in priority order and rejects a policy that repeats a priority, so a collision is an apply time failure after a clean plan."
  }
}

run "the_keep_last_ten_rule_is_the_default_and_counts_images_not_days" {
  command = plan

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].selection.countNumber == 10
    error_message = "keep_last_tagged_images must default to 10. This is the number the whole estate relies on, and it is also the known trap: a bootstrap image tag older than the last ten builds has already been expired out of ECR, so a plan that still references it is green while the apply fails to pull it."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].selection.countType == "imageCountMoreThan"
    error_message = "The tagged rule must count images with imageCountMoreThan, not age. Counting by age would expire the live image of a domain that simply has not been deployed for a while."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].selection.tagStatus == "tagged"
    error_message = "The keep last N rule must select tagStatus tagged; applied to untagged images it would fight the first rule rather than complement it."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].action.type == "expire"
    error_message = "The only action ECR lifecycle rules support is expire, and it must be spelt exactly so or the policy is rejected."
  }

  assert {
    condition     = !contains(keys(jsondecode(local.lifecycle_policies["content"]).rules[1].selection), "countUnit")
    error_message = "A countType of imageCountMoreThan must carry no countUnit: ECR rejects the combination, since a count of images has no unit of time."
  }
}

run "the_tagged_rule_selects_on_the_sha_prefix_this_estate_pushes" {
  command = plan

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].selection.tagPrefixList == ["sha-"]
    error_message = "tag_prefix_list must default to sha-, matching the sha-<commit> tags CI pushes. ECR requires a tagPrefixList or tagPatternList on a tagged rule, and a tagged image that matches no prefix is never expired by the rule, so the list has to cover every tag scheme in the repository."
  }

  assert {
    condition     = length(jsondecode(local.lifecycle_policies["content"]).rules[1].selection.tagPrefixList) > 0
    error_message = "The prefix list must never render empty: ECR rejects a tagged rule that carries neither a tagPrefixList nor a tagPatternList."
  }
}

run "the_untagged_rule_expires_by_age_after_one_day_by_default" {
  command = plan

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[0].selection.tagStatus == "untagged"
    error_message = "The first rule must select untagged images. Untagged images are the layers left behind when a tag moves or a build is replaced, and they are what accumulates silently."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[0].selection.countType == "sinceImagePushed"
    error_message = "Untagged images must be expired by age with sinceImagePushed, not by count, so that cost at rest stays flat regardless of how many builds ran."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[0].selection.countUnit == "days"
    error_message = "A countType of sinceImagePushed requires a countUnit of days; ECR rejects the rule without it."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[0].selection.countNumber == 1
    error_message = "expire_untagged_after_days must default to 1: an untagged image is already superseded, so there is nothing to gain by keeping it longer."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[0].action.type == "expire"
    error_message = "The untagged rule's action must be expire, the only action ECR supports."
  }
}

run "the_rule_descriptions_agree_in_number_with_the_counts_they_describe" {
  command = plan

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[0].description == "Expire untagged images after 1 day"
    error_message = "A count of one must read \"1 day\", not \"1 days\". The description is the only thing a responder sees in the ECR console, so it must not contradict the rule beside it."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].description == "Keep the last 10 tagged images"
    error_message = "The tagged rule's description must state the count it actually enforces, so the console explains why an image a consumer expected to find is gone."
  }
}

run "the_descriptions_pluralise_correctly_at_other_counts" {
  command = plan

  variables {
    expire_untagged_after_days = 14
    keep_last_tagged_images    = 1
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[0].description == "Expire untagged images after 14 days"
    error_message = "A count above one must read \"14 days\" in the plural."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].description == "Keep the last 1 tagged image"
    error_message = "A count of exactly one tagged image must read \"image\" in the singular, so the description stays honest at the boundary."
  }
}

run "module_wide_counts_reach_every_repository" {
  command = plan

  variables {
    keep_last_tagged_images    = 30
    expire_untagged_after_days = 7
    tag_prefix_list            = ["sha-", "release-"]
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      jsondecode(local.lifecycle_policies[key]).rules[1].selection.countNumber == 30
    ])
    error_message = "A module wide keep count must apply to every repository, so one input raises the headroom for the whole environment at once."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      jsondecode(local.lifecycle_policies[key]).rules[0].selection.countNumber == 7
    ])
    error_message = "A module wide untagged age must apply to every repository for the same reason."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      length(jsondecode(local.lifecycle_policies[key]).rules[1].selection.tagPrefixList) == 2
    ])
    error_message = "Both prefixes must reach every repository. A repository that pushes two tag schemes needs both listed, because a tagged image matching no prefix is never expired and quietly defeats the keep last N rule."
  }
}

run "a_repository_override_beats_the_module_wide_value_for_that_repository_alone" {
  command = plan

  variables {
    keep_last_tagged_images    = 10
    expire_untagged_after_days = 1

    repositories = {
      content = {}
      identity = {
        keep_last_tagged_images    = 50
        expire_untagged_after_days = 30
        tag_prefix_list            = ["release-"]
      }
    }
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["identity"]).rules[1].selection.countNumber == 50
    error_message = "A per repository keep count must win over the module wide one, which is how a domain that needs more rollback headroom gets it without raising storage for every other domain."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["identity"]).rules[0].selection.countNumber == 30
    error_message = "A per repository untagged age must win over the module wide one."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["identity"]).rules[1].selection.tagPrefixList == ["release-"]
    error_message = "A per repository tag prefix list must replace the module wide one rather than merge with it, so the override is a complete statement of what that repository tags."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].selection.countNumber == 10
    error_message = "An override on one repository must leave every other repository on the module wide value; overrides that leak would change expiry for domains nobody touched."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["content"]).rules[1].selection.tagPrefixList == ["sha-"]
    error_message = "The repository with no override must keep the module wide prefix list."
  }
}

run "a_verbatim_lifecycle_policy_replaces_every_generated_rule_for_that_repository" {
  command = plan

  variables {
    repositories = {
      content = {}
      special = {
        keep_last_tagged_images = 99
        lifecycle_policy = jsonencode({
          rules = [
            {
              rulePriority = 1
              description  = "Expire everything older than 90 days"
              selection = {
                tagStatus   = "any"
                countType   = "sinceImagePushed"
                countUnit   = "days"
                countNumber = 90
              }
              action = { type = "expire" }
            },
          ]
        })
      }
    }
  }

  assert {
    condition     = length(jsondecode(local.lifecycle_policies["special"]).rules) == 1
    error_message = "An explicit lifecycle_policy must be written verbatim and must not be merged with the generated rules, because merging would produce a policy with duplicate rule priorities that ECR rejects."
  }

  assert {
    condition     = jsondecode(local.lifecycle_policies["special"]).rules[0].selection.tagStatus == "any"
    error_message = "The verbatim policy must reach the resource exactly as written; it is the escape hatch for a policy the two generated rules cannot express."
  }

  assert {
    condition     = length(jsondecode(local.lifecycle_policies["content"]).rules) == 2
    error_message = "One repository opting out of the generated rules must not change the policy of any other repository in the same module block."
  }
}

run "the_lifecycle_policy_can_be_turned_off_for_every_repository" {
  command = plan

  variables {
    create_lifecycle_policy = false
  }

  assert {
    condition     = length(aws_ecr_lifecycle_policy.this) == 0
    error_message = "create_lifecycle_policy false must create no policy at all. It exists so a repository can be adopted before its policy is, not as a setting to leave off: with no policy nothing is ever expired."
  }

  assert {
    condition     = length(local.lifecycle_policies) == 0
    error_message = "With policies turned off the computed map must be empty, so nothing downstream can resurrect a policy for a repository."
  }

  assert {
    condition     = length(aws_ecr_repository.this) == 4
    error_message = "Turning the lifecycle policy off must leave every repository itself in place; only the expiry rules go away."
  }
}

run "a_module_wide_keep_count_of_zero_is_rejected" {
  command = plan

  variables {
    keep_last_tagged_images = 0
  }

  expect_failures = [var.keep_last_tagged_images]
}

run "a_fractional_module_wide_keep_count_is_rejected" {
  command = plan

  variables {
    keep_last_tagged_images = 10.5
  }

  expect_failures = [var.keep_last_tagged_images]
}

run "a_module_wide_untagged_age_of_zero_is_rejected" {
  command = plan

  variables {
    expire_untagged_after_days = 0
  }

  expect_failures = [var.expire_untagged_after_days]
}

run "a_fractional_module_wide_untagged_age_is_rejected" {
  command = plan

  variables {
    expire_untagged_after_days = 1.5
  }

  expect_failures = [var.expire_untagged_after_days]
}

run "an_empty_module_wide_tag_prefix_list_is_rejected" {
  command = plan

  variables {
    tag_prefix_list = []
  }

  expect_failures = [var.tag_prefix_list]
}

run "an_empty_string_in_the_tag_prefix_list_is_rejected" {
  command = plan

  variables {
    tag_prefix_list = ["sha-", ""]
  }

  expect_failures = [var.tag_prefix_list]
}

run "a_per_repository_keep_count_of_zero_is_rejected" {
  command = plan

  variables {
    repositories = {
      content = {
        keep_last_tagged_images = 0
      }
    }
  }

  expect_failures = [var.repositories]
}

run "a_per_repository_untagged_age_of_zero_is_rejected" {
  command = plan

  variables {
    repositories = {
      content = {
        expire_untagged_after_days = 0
      }
    }
  }

  expect_failures = [var.repositories]
}

run "a_per_repository_empty_tag_prefix_list_is_rejected" {
  command = plan

  variables {
    repositories = {
      content = {
        tag_prefix_list = []
      }
    }
  }

  expect_failures = [var.repositories]
}
