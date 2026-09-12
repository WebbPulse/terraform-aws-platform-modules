variables {
  role_name = "example-staging-github-actions-deploy"
  subjects  = ["repo:WebbPulse/ExampleRepo:*"]
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

run "the_role_name_is_taken_verbatim_rather_than_being_treated_as_a_prefix" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "example-staging-github-actions-deploy"
    error_message = "role_name must be the role's name exactly as given, with nothing appended. Consumers pass the whole name and record it as AWS_DEPLOY_ROLE_ARN on the GitHub environment, so any decoration would silently break every workflow that already holds the old ARN."
  }

  assert {
    condition     = output.role_name == "example-staging-github-actions-deploy"
    error_message = "The role_name output exists so a caller can attach further policies from outside; it must give back the name that was set."
  }

  assert {
    condition     = aws_iam_role.this.name == var.role_name
    error_message = "The resource must set name straight from the input, with no prefix or generated suffix: a generated suffix would make the ARN unpredictable and unusable as the AWS_DEPLOY_ROLE_ARN a workflow reads."
  }
}

run "the_defaults_match_what_configure_aws_credentials_asks_for" {
  command = plan

  assert {
    condition     = aws_iam_role.this.max_session_duration == 3600
    error_message = "max_session_duration must default to 3600 seconds, which is what aws-actions/configure-aws-credentials requests unless told otherwise. A role whose maximum is below the requested duration fails the assume call outright."
  }

  assert {
    condition     = aws_iam_role.this.path == "/"
    error_message = "The role path must default to the root path, because the path is part of the ARN and changing it replaces the role rather than updating it."
  }

  assert {
    condition     = aws_iam_role.this.description == null
    error_message = "role_description must default to null so a role that never had a description plans clean; an empty string is a different value to IAM."
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "No permissions boundary must be set unless one is asked for, since a boundary caps everything the inline policy grants and an accidental one would look like a permissions bug at deploy time."
  }
}

run "the_optional_role_attributes_reach_the_resource_when_set" {
  command = plan

  variables {
    role_description         = "Read only CodeArtifact access for pull request CI in WebbPulse/ExampleRepo."
    role_path                = "/deploy/"
    max_session_duration     = 7200
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/example-staging-boundary"
  }

  assert {
    condition     = aws_iam_role.this.description == "Read only CodeArtifact access for pull request CI in WebbPulse/ExampleRepo."
    error_message = "A description is how the next reader of the account tells the deploy role from the CI role, so it must reach the resource."
  }

  assert {
    condition     = aws_iam_role.this.path == "/deploy/"
    error_message = "A non default path must reach the resource, because it becomes part of the ARN the workflow assumes."
  }

  assert {
    condition     = aws_iam_role.this.max_session_duration == 7200
    error_message = "A longer session must reach the resource; a deploy that outruns the session expires mid run with a credentials error rather than a deploy error."
  }

  assert {
    condition     = aws_iam_role.this.permissions_boundary == "arn:aws:iam::123456789012:policy/example-staging-boundary"
    error_message = "A permissions boundary must be set on the role when one is given, or the cap the caller asked for simply is not applied."
  }
}

run "tags_are_null_by_default_so_a_role_that_never_set_them_plans_clean" {
  command = plan

  assert {
    condition     = local.tags == null
    error_message = "An empty tags map must become null rather than an empty map. The estate relies on provider default_tags and never set resource tags explicitly, so passing an empty map would show as a change on roles that are already correct."
  }

  assert {
    condition     = aws_iam_role.this.tags == null
    error_message = "The role must carry no explicit tags by default, leaving the provider's default_tags as the only source."
  }

  assert {
    condition     = one(aws_iam_openid_connect_provider.this[*].tags) == null
    error_message = "The created OIDC provider must also carry no explicit tags by default, for the same reason the role does."
  }
}

run "tags_reach_both_the_role_and_the_created_provider_when_given" {
  command = plan

  variables {
    tags = {
      Project     = "example"
      Environment = "staging"
    }
  }

  assert {
    condition     = aws_iam_role.this.tags["Project"] == "example"
    error_message = "Explicit tags must reach the role, since tag based cost allocation and tag conditioned policies both read them off the resource."
  }

  assert {
    condition     = one(aws_iam_openid_connect_provider.this[*].tags)["Environment"] == "staging"
    error_message = "The same tags must reach the OIDC provider when it is created here, so the two resources this module owns are labelled consistently."
  }
}

run "the_inline_policy_is_attached_to_this_module_s_own_role" {
  command = plan

  variables {
    policy_statements = [
      {
        actions   = ["ecr:GetAuthorizationToken"]
        resources = ["*"]
      },
    ]
  }

  override_resource {
    target          = aws_iam_role.this
    override_during = plan
    values = {
      id = "example-staging-github-actions-deploy"
    }
  }

  assert {
    condition     = one(aws_iam_role_policy.this[*].role) == "example-staging-github-actions-deploy"
    error_message = "The inline policy must be bound to the role this module created and no other, or the permissions land on a role nobody assumes while the deploy role stays empty. An aws_iam_role's id is its name, so the binding is checked against the name the caller configured."
  }
}

run "a_role_name_over_sixty_four_characters_is_rejected" {
  command = plan

  variables {
    role_name = "example-staging-github-actions-deploy-with-a-name-that-is-far-too-long-for-iam"
  }

  expect_failures = [var.role_name]
}

run "a_role_name_with_a_character_iam_forbids_is_rejected" {
  command = plan

  variables {
    role_name = "example staging deploy"
  }

  expect_failures = [var.role_name]
}

run "an_empty_role_name_is_rejected" {
  command = plan

  variables {
    role_name = ""
  }

  expect_failures = [var.role_name]
}

run "a_role_path_without_a_leading_slash_is_rejected" {
  command = plan

  variables {
    role_path = "deploy/"
  }

  expect_failures = [var.role_path]
}

run "a_role_path_without_a_trailing_slash_is_rejected" {
  command = plan

  variables {
    role_path = "/deploy"
  }

  expect_failures = [var.role_path]
}

run "a_session_duration_below_the_iam_minimum_is_rejected" {
  command = plan

  variables {
    max_session_duration = 900
  }

  expect_failures = [var.max_session_duration]
}

run "a_session_duration_above_the_iam_maximum_is_rejected" {
  command = plan

  variables {
    max_session_duration = 43201
  }

  expect_failures = [var.max_session_duration]
}
