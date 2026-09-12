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

run "a_repository_is_named_prefix_slash_key_so_the_console_groups_an_environment" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository.this) == 4
    error_message = "One repository must be created per entry in repositories: the estate keeps one repository per domain function per environment, which is what makes \"keep the last 10 tagged images\" mean the last 10 builds of that domain."
  }

  assert {
    condition     = aws_ecr_repository.this["content"].name == "example-staging/content"
    error_message = "The repository name must be <name_prefix>/<key>. The slash reads as a namespace and the ECR console groups on it, so one environment's domain repositories sort together instead of scattering through the registry."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : aws_ecr_repository.this[key].name == "example-staging/${key}"
    ])
    error_message = "Every repository must follow the same naming rule, since CI builds the image reference from the key and would push to a repository that does not exist if any key were transformed."
  }

  assert {
    condition     = local.repository_names["identity"] == "example-staging/identity"
    error_message = "The computed name map must agree with the resource, because it is what the lifecycle policy and repository policy resources address the repository by."
  }
}

run "an_empty_name_prefix_uses_the_key_verbatim_with_no_leading_slash" {
  command = plan

  variables {
    name_prefix = ""

    repositories = {
      "webbpulse/python-lambda-base" = {}
    }
  }

  assert {
    condition     = aws_ecr_repository.this["webbpulse/python-lambda-base"].name == "webbpulse/python-lambda-base"
    error_message = "With no prefix the key must become the whole repository name, with no leading slash. A leading slash is not a valid ECR repository name, so getting this wrong is an apply time rejection rather than a cosmetic problem."
  }

  assert {
    condition     = !startswith(local.repository_names["webbpulse/python-lambda-base"], "/")
    error_message = "The computed name must never begin with a slash, which is what the empty prefix branch exists to prevent."
  }
}

run "images_are_immutable_and_scanned_on_push_by_default" {
  command = plan

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : aws_ecr_repository.this[key].image_tag_mutability == "IMMUTABLE"
    ])
    error_message = "Tags must be IMMUTABLE by default. A commit SHA tag that cannot move is what makes a deploy reproducible and makes the digest a Lambda records meaningful; under MUTABLE the same tag can point at different code on two different days."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : one(aws_ecr_repository.this[key].image_scanning_configuration).scan_on_push
    ])
    error_message = "Basic scan on push must be on by default. It is the free ECR scanner, it covers operating system package CVEs, and an image that is never scanned is one nobody finds out about."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : aws_ecr_repository.this[key].force_delete == false
    ])
    error_message = "force_delete must default to false so a destroy fails while images remain, rather than silently deleting the images a live Lambda still pulls from."
  }
}

run "the_module_wide_switches_can_each_be_flipped_for_every_repository" {
  command = plan

  variables {
    image_tag_mutability = "MUTABLE"
    scan_on_push         = false
    force_delete         = true
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : aws_ecr_repository.this[key].image_tag_mutability == "MUTABLE"
    ])
    error_message = "A module wide MUTABLE must reach every repository. Mutability is a repository level setting rather than a per tag one, so a repository that needs a moving tag such as env-staging has to take MUTABLE wholesale."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : !one(aws_ecr_repository.this[key].image_scanning_configuration).scan_on_push
    ])
    error_message = "Turning scanning off module wide must reach every repository rather than being silently ignored."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : aws_ecr_repository.this[key].force_delete == true
    ])
    error_message = "A module wide force_delete must reach every repository, which is how a whole staging environment is torn down without emptying each registry by hand first."
  }
}

run "a_repository_can_override_each_switch_without_affecting_its_neighbours" {
  command = plan

  variables {
    image_tag_mutability = "IMMUTABLE"
    scan_on_push         = true
    force_delete         = false

    repositories = {
      content = {}
      scratch = {
        image_tag_mutability = "MUTABLE"
        scan_on_push         = false
        force_delete         = true
      }
    }
  }

  assert {
    condition     = aws_ecr_repository.this["scratch"].image_tag_mutability == "MUTABLE"
    error_message = "A per repository mutability override must win over the module wide value."
  }

  assert {
    condition     = !one(aws_ecr_repository.this["scratch"].image_scanning_configuration).scan_on_push
    error_message = "A per repository scan_on_push override must win over the module wide value. It is a boolean, so the module has to distinguish an explicit false from an unset null rather than treating both as absent."
  }

  assert {
    condition     = aws_ecr_repository.this["scratch"].force_delete == true
    error_message = "A per repository force_delete override must win over the module wide value, and for the same reason must distinguish an explicit false from null."
  }

  assert {
    condition     = aws_ecr_repository.this["content"].image_tag_mutability == "IMMUTABLE"
    error_message = "An override on one repository must leave every other repository on the module wide value; a leaking override would quietly make a production repository's tags movable."
  }

  assert {
    condition     = one(aws_ecr_repository.this["content"].image_scanning_configuration).scan_on_push
    error_message = "The repository with no override must keep the module wide scan setting."
  }

  assert {
    condition     = aws_ecr_repository.this["content"].force_delete == false
    error_message = "The repository with no override must keep the safe module wide force_delete."
  }
}

run "an_explicit_per_repository_false_is_honoured_rather_than_read_as_unset" {
  command = plan

  variables {
    scan_on_push = true
    force_delete = true

    repositories = {
      content = {
        scan_on_push = false
        force_delete = false
      }
    }
  }

  assert {
    condition     = !one(aws_ecr_repository.this["content"].image_scanning_configuration).scan_on_push
    error_message = "An explicit false must override a module wide true. This is the case a naive coalesce of a bare boolean gets wrong, because false and null are easy to conflate, and getting it wrong silently ignores what the caller asked for."
  }

  assert {
    condition     = aws_ecr_repository.this["content"].force_delete == false
    error_message = "An explicit force_delete of false must override a module wide true, so a repository can be protected inside an environment that is otherwise disposable."
  }
}

run "encryption_defaults_to_the_ecr_managed_key_with_no_kms_key_set" {
  command = plan

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      one(aws_ecr_repository.this[key].encryption_configuration).encryption_type == "AES256"
    ])
    error_message = "Encryption must default to AES256, the ECR managed key. KMS adds a request charge on top of every layer upload and every pull and buys nothing here that AES256 does not already give."
  }

  assert {
    condition     = var.encryption_type == "AES256" ? var.encryption_kms_key == null : true
    error_message = "Under AES256 no KMS key may be configured. Passing a key alongside AES256 is a configuration ECR rejects, and encryption is fixed at creation so the mistake replaces every repository rather than being correctable in place."
  }
}

run "a_customer_managed_key_reaches_every_repository_under_kms_encryption" {
  command = plan

  variables {
    encryption_type    = "KMS"
    encryption_kms_key = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      one(aws_ecr_repository.this[key].encryption_configuration).encryption_type == "KMS"
    ])
    error_message = "The KMS encryption type must reach every repository, since encryption is a repository wide creation time setting."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      one(aws_ecr_repository.this[key].encryption_configuration).kms_key == "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    ])
    error_message = "The supplied key must reach every repository. Encryption is fixed when a repository is created, so a key that fails to reach the resource cannot be corrected without replacing the repository and re-pushing every image."
  }
}

run "kms_encryption_with_no_key_falls_back_to_the_aws_managed_ecr_key" {
  command = plan

  variables {
    encryption_type = "KMS"
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      one(aws_ecr_repository.this[key].encryption_configuration).encryption_type == "KMS"
    ])
    error_message = "The KMS encryption type must still reach every repository when no key is named."
  }

  assert {
    condition     = var.encryption_kms_key == null
    error_message = "A null key under KMS must stay null so ECR falls back to the AWS managed aws/ecr key for the account, rather than the module inventing a key ARN of its own."
  }
}

run "tags_are_null_by_default_so_a_repository_that_never_set_them_plans_clean" {
  command = plan

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : aws_ecr_repository.this[key].tags == null
    ])
    error_message = "An empty tags map must be passed to the provider as null rather than an empty map, so a repository that never set resource tags plans identically and relies on the provider default_tags alone."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) : length(local.repository_tags[key]) == 0
    ])
    error_message = "With no module tags and no per repository tags the merged map must be empty, which is what drives the null."
  }
}

run "module_tags_and_per_repository_tags_merge_with_the_repository_winning" {
  command = plan

  variables {
    tags = {
      Project     = "example"
      Environment = "staging"
    }

    repositories = {
      content = {}
      identity = {
        tags = {
          Environment = "production"
          Domain      = "identity"
        }
      }
    }
  }

  assert {
    condition     = aws_ecr_repository.this["content"].tags["Project"] == "example"
    error_message = "Module wide tags must reach a repository that adds none of its own."
  }

  assert {
    condition     = aws_ecr_repository.this["identity"].tags["Project"] == "example"
    error_message = "A repository adding its own tags must still inherit the module wide ones rather than replacing them, since the per repository map is described as extra tags on top."
  }

  assert {
    condition     = aws_ecr_repository.this["identity"].tags["Environment"] == "production"
    error_message = "Where both maps set the same key the repository's value must win, which is what makes the per repository map an override rather than a suggestion."
  }

  assert {
    condition     = aws_ecr_repository.this["identity"].tags["Domain"] == "identity"
    error_message = "A key only the repository sets must survive the merge."
  }

  assert {
    condition     = !contains(keys(aws_ecr_repository.this["content"].tags), "Domain")
    error_message = "One repository's tags must not leak onto another; tags drive cost allocation and a leaked one misattributes spend."
  }
}

run "no_repositories_creates_nothing_at_all" {
  command = plan

  variables {
    repositories = {}
  }

  assert {
    condition     = length(aws_ecr_repository.this) == 0
    error_message = "An empty repositories map must create no repositories, so a consumer can wire the module in before it knows its domain list."
  }

  assert {
    condition     = length(aws_ecr_lifecycle_policy.this) == 0
    error_message = "With no repositories there must be no lifecycle policies: a policy resource needs a repository to attach to."
  }
}

run "a_name_prefix_ending_in_a_slash_is_rejected" {
  command = plan

  variables {
    name_prefix = "example-staging/"
  }

  expect_failures = [var.name_prefix]
}

run "an_uppercase_name_prefix_is_rejected" {
  command = plan

  variables {
    name_prefix = "Example-Staging"
  }

  expect_failures = [var.name_prefix]
}

run "a_repository_key_with_an_uppercase_letter_is_rejected" {
  command = plan

  variables {
    repositories = {
      Content = {}
    }
  }

  expect_failures = [var.repositories]
}

run "a_repository_key_with_a_space_is_rejected" {
  command = plan

  variables {
    repositories = {
      "build logs" = {}
    }
  }

  expect_failures = [var.repositories]
}

run "a_per_repository_mutability_that_is_not_a_valid_ecr_value_is_rejected" {
  command = plan

  variables {
    repositories = {
      content = {
        image_tag_mutability = "immutable"
      }
    }
  }

  expect_failures = [var.repositories]
}

run "a_module_wide_mutability_that_is_not_a_valid_ecr_value_is_rejected" {
  command = plan

  variables {
    image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"
  }

  expect_failures = [var.image_tag_mutability]
}

run "an_unsupported_encryption_type_is_rejected" {
  command = plan

  variables {
    encryption_type = "AES128"
  }

  expect_failures = [var.encryption_type]
}

run "a_kms_key_alongside_aes256_encryption_is_rejected" {
  command = plan

  variables {
    encryption_type    = "AES256"
    encryption_kms_key = "arn:aws:kms:us-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [var.encryption_kms_key]
}
