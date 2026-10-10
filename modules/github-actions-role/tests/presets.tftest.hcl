variables {
  role_name = "example-staging-github-actions-deploy"
  subjects  = ["repo:WebbPulse/ExampleRepo:environment:production"]

  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
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

run "no_presets_leaves_the_policy_exactly_as_the_statements_render_it" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "EcrAuth"
        actions   = ["ecr:GetAuthorizationToken"]
        resources = ["*"]
      },
    ]
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement == [{ Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*", Sid = "EcrAuth" }]
    error_message = "With every preset null the inline policy must be exactly the rendered policy_statements, so an existing caller plans no change."
  }
}

run "the_lambda_preset_grants_deploy_and_defaults_invoke_to_the_same_functions" {
  command = plan

  variables {
    lambda_image_deploy = {
      function_arns = ["arn:aws:lambda:us-west-2:123456789012:function:example-staging-api"]
    }
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "A preset alone, with no policy_statements, must still create the inline policy."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement :
      s.Sid == "LambdaImageDeploy" && contains(s.Action, "lambda:UpdateFunctionCode") && contains(s.Action, "lambda:GetFunctionCodeSigningConfig") && s.Resource == "arn:aws:lambda:us-west-2:123456789012:function:example-staging-api"
    ])
    error_message = "The Lambda preset must grant the image deploy actions on exactly the given functions."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement :
      s.Sid == "LambdaSmokeInvoke" && s.Action == "lambda:InvokeFunction" && s.Resource == "arn:aws:lambda:us-west-2:123456789012:function:example-staging-api"
    ])
    error_message = "With invoke_function_arns null the smoke invoke grant must cover the deployed functions."
  }
}

run "an_empty_invoke_list_drops_the_invoke_statement" {
  command = plan

  variables {
    lambda_image_deploy = {
      function_arns        = ["arn:aws:lambda:us-west-2:123456789012:function:example-staging-api"]
      invoke_function_arns = []
    }
  }

  assert {
    condition     = length(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement) == 1
    error_message = "An empty invoke_function_arns must grant no lambda:InvokeFunction at all."
  }
}

run "the_ecr_preset_grants_auth_push_and_pull_without_set_repository_policy" {
  command = plan

  variables {
    ecr_push = {
      repository_arns      = ["arn:aws:ecr:us-west-2:123456789012:repository/example-staging/api"]
      pull_repository_arns = ["arn:aws:ecr:us-west-2:432410731887:repository/webbpulse/python-lambda-base"]
    }
  }

  assert {
    condition     = [for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement : s.Sid] == ["EcrAuth", "EcrPush", "EcrPull"]
    error_message = "The ECR preset must add the auth, push and pull statements in that order."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement :
      s.Sid != "EcrAuth" || (s.Action == "ecr:GetAuthorizationToken" && s.Resource == "*")
    ])
    error_message = "ecr:GetAuthorizationToken has no resource-level permissions, so it must be granted on *."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement :
      s.Sid != "EcrPush" || (contains(s.Action, "ecr:PutImage") && !contains(s.Action, "ecr:SetRepositoryPolicy"))
    ])
    error_message = "The push statement must grant ecr:PutImage and must not grant ecr:SetRepositoryPolicy, which lets the role rewrite who can pull."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement :
      s.Sid != "EcrPull" || (!contains(s.Action, "ecr:PutImage") && s.Resource == "arn:aws:ecr:us-west-2:432410731887:repository/webbpulse/python-lambda-base")
    ])
    error_message = "The pull statement must be read only and name the pull repositories alone."
  }
}

run "the_spa_preset_grants_the_bucket_its_objects_and_the_invalidation" {
  command = plan

  variables {
    spa_deploy = {
      bucket_arns       = ["arn:aws:s3:::example-staging-frontend"]
      distribution_arns = ["arn:aws:cloudfront::123456789012:distribution/E1ABCDEFGHIJKL"]
    }
  }

  assert {
    condition = anytrue([
      for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement :
      s.Sid == "SpaSync" && s.Resource == ["arn:aws:s3:::example-staging-frontend", "arn:aws:s3:::example-staging-frontend/*"] && contains(s.Action, "s3:DeleteObject")
    ])
    error_message = "The SPA preset must grant the sync actions on the bucket and every object in it, since ListBucket is a bucket action and the object actions need the /* form."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement :
      s.Sid == "SpaInvalidate" && s.Resource == "arn:aws:cloudfront::123456789012:distribution/E1ABCDEFGHIJKL"
    ])
    error_message = "The SPA preset must grant the invalidation on the given distribution."
  }
}

run "presets_append_after_hand_written_statements" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "CodeArtifactToken"
        actions   = ["codeartifact:GetAuthorizationToken"]
        resources = ["*"]
      },
    ]
    spa_deploy = {
      bucket_arns = ["arn:aws:s3:::example-staging-frontend"]
    }
  }

  assert {
    condition     = [for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement : s.Sid] == ["CodeArtifactToken", "SpaSync"]
    error_message = "Preset statements must follow policy_statements in the one inline policy, and an empty distribution_arns must add no invalidation statement."
  }
}

run "a_hand_written_sid_that_collides_with_a_preset_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "EcrAuth"
        actions   = ["ecr:GetAuthorizationToken"]
        resources = ["*"]
      },
    ]
    ecr_push = {
      repository_arns = ["arn:aws:ecr:us-west-2:123456789012:repository/example-staging/api"]
    }
  }

  expect_failures = [aws_iam_role_policy.this]
}

run "a_qualified_function_arn_is_rejected" {
  command = plan

  variables {
    lambda_image_deploy = {
      function_arns = ["arn:aws:lambda:us-west-2:123456789012:function:example-staging-api:live"]
    }
  }

  expect_failures = [var.lambda_image_deploy]
}

run "a_bucket_object_arn_is_rejected" {
  command = plan

  variables {
    spa_deploy = {
      bucket_arns = ["arn:aws:s3:::example-staging-frontend/*"]
    }
  }

  expect_failures = [var.spa_deploy]
}

run "a_repository_url_is_rejected" {
  command = plan

  variables {
    ecr_push = {
      repository_arns = ["123456789012.dkr.ecr.us-west-2.amazonaws.com/example-staging/api"]
    }
  }

  expect_failures = [var.ecr_push]
}

run "presets_do_not_touch_the_trust_policy" {
  command = plan

  variables {
    ecr_push = {
      repository_arns = ["arn:aws:ecr:us-west-2:123456789012:repository/example-staging/api"]
    }
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] == "repo:WebbPulse/ExampleRepo:environment:production"
    error_message = "The presets only add permission statements; the trust subjects must render exactly as before."
  }
}
