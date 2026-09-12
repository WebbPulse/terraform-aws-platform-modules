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

run "no_statements_creates_no_inline_policy_at_all" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.this) == 0
    error_message = "policy_statements defaults to an empty list and must create no inline policy. IAM rejects a policy document with an empty Statement array, so the resource has to disappear rather than render empty."
  }

  assert {
    condition     = aws_iam_role.this.name == "example-staging-github-actions-deploy"
    error_message = "The role itself must still be created when there are no statements, which is what lets a caller take the role_name output and attach permissions from outside the module."
  }

  assert {
    condition     = length(local.policy_statements) == 0
    error_message = "With no input statements the rendered statement list must be empty, which is what drives the inline policy resource to a count of zero rather than rendering a document IAM would reject."
  }
}

run "statements_become_one_inline_policy_under_the_configured_name" {
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
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "Every statement must land in a single inline policy, so the deploy permissions are one document to read rather than a scatter of managed policy attachments."
  }

  assert {
    condition     = one(aws_iam_role_policy.this[*].name) == "deploy-permissions"
    error_message = "The inline policy name must default to deploy-permissions, which is the name already on every deploy role in the estate; changing it destroys the old policy and creates a new one."
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Version == "2012-10-17"
    error_message = "The inline policy must declare the 2012-10-17 policy language version, without which IAM rejects the document."
  }
}

run "the_inline_policy_name_is_overridable_for_a_role_that_is_not_a_deploy_role" {
  command = plan

  variables {
    inline_policy_name = "codeartifact-read"

    policy_statements = [
      {
        sid       = "CodeArtifactToken"
        actions   = ["codeartifact:GetAuthorizationToken"]
        resources = ["arn:aws:codeartifact:us-west-2:432410731887:domain/webbpulse"]
      },
    ]
  }

  assert {
    condition     = one(aws_iam_role_policy.this[*].name) == "codeartifact-read"
    error_message = "Both consumer estates name the CI role's policy codeartifact-read so the policy name says what the role is for; the override must reach the resource."
  }
}

run "a_single_action_and_resource_collapse_to_bare_strings" {
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
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Action == "ecr:GetAuthorizationToken"
    error_message = "A statement with one action must render Action as a bare string, the way a hand written policy is spelt. IAM accepts either shape, so the only thing at stake is whether the document matches what is already deployed, and a one element array would show as a change on every existing role."
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Resource == "*"
    error_message = "A statement with one resource must render Resource as a bare string for the same reason the single action does."
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Sid == "EcrAuth"
    error_message = "A supplied sid must reach the document: it is the only handle a reader has on which statement a denied call was supposed to match."
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Effect == "Allow"
    error_message = "effect must default to Allow, because a statement with no effect is not a valid IAM statement and Allow is what every caller means."
  }
}

run "several_actions_and_resources_render_as_lists" {
  command = plan

  variables {
    policy_statements = [
      {
        sid = "EcrPushDomainImages"
        actions = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        resources = [
          "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/content",
          "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/identity",
        ]
      },
    ]
  }

  assert {
    condition     = length(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Action) == 5
    error_message = "Five actions must render as a five element array, in the order given, so the document reads the same as the input."
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Action[0] == "ecr:BatchCheckLayerAvailability"
    error_message = "Actions must keep their input order rather than being sorted, so a diff of the rendered policy tracks the diff of the module block."
  }

  assert {
    condition     = length(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Resource) == 2
    error_message = "Two resources must render as a two element array. This is the shape the ECR push grant takes, where the resource list comes straight from the registry module's repository_arns_list output."
  }
}

run "a_statement_without_a_sid_omits_the_key_entirely" {
  command = plan

  variables {
    policy_statements = [
      {
        actions   = ["lambda:UpdateFunctionCode", "lambda:PublishVersion"]
        resources = ["arn:aws:lambda:us-west-2:123456789012:function:example-staging-content"]
      },
    ]
  }

  assert {
    condition     = !contains(keys(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0]), "Sid")
    error_message = "A statement with no sid must omit the Sid key rather than render it as null. IAM rejects a null Sid, and both consumer estates leave the sid off most of their lambda and s3 statements."
  }

  assert {
    condition     = !contains(keys(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0]), "Condition")
    error_message = "A statement with no condition must omit the Condition key; an empty or null Condition is not a valid IAM statement."
  }

  assert {
    condition     = !contains(keys(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0]), "NotAction")
    error_message = "A statement built from actions must carry no NotAction key at all: IAM rejects a statement that carries both."
  }

  assert {
    condition     = !contains(keys(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0]), "NotResource")
    error_message = "A statement built from resources must carry no NotResource key, for the same reason NotAction must be absent."
  }
}

run "a_condition_collapses_its_single_value_and_keeps_its_operator_and_key" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "CodeArtifactBearerToken"
        actions   = ["sts:GetServiceBearerToken"]
        resources = ["*"]
        condition = {
          StringEquals = {
            "sts:AWSServiceName" = ["codeartifact.amazonaws.com"]
          }
        }
      },
    ]
  }

  assert {
    condition     = keys(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Condition) == ["StringEquals"]
    error_message = "The condition operator must reach the document under its own name: an operator is the difference between an exact match and a prefix match, and it cannot be inferred."
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Condition.StringEquals["sts:AWSServiceName"] == "codeartifact.amazonaws.com"
    error_message = "A condition key with one value must render that value as a bare string, matching the way the same statement is spelt in both consumer estates today."
  }
}

run "a_condition_with_several_values_renders_as_a_list" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "TaggedResourcesOnly"
        actions   = ["ec2:StopInstances"]
        resources = ["*"]
        condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = ["example-staging", "example-production"]
          }
        }
      },
    ]
  }

  assert {
    condition     = length(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Condition.StringEquals["aws:ResourceTag/Project"]) == 2
    error_message = "A condition key with two values must render as an array, which IAM reads as an OR across them."
  }
}

run "not_actions_and_not_resources_render_under_their_own_keys" {
  command = plan

  variables {
    policy_statements = [
      {
        sid           = "DenyEverythingOutsideTheRegion"
        effect        = "Deny"
        not_actions   = ["iam:*", "sts:*"]
        not_resources = ["arn:aws:s3:::example-staging-frontend"]
      },
    ]
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].Effect == "Deny"
    error_message = "An explicit Deny effect must reach the document unchanged: a Deny silently rendered as Allow is the worst possible failure mode for this module."
  }

  assert {
    condition     = length(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].NotAction) == 2
    error_message = "not_actions must render as NotAction, with the same one or many collapse the positive form gets."
  }

  assert {
    condition     = jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0].NotResource == "arn:aws:s3:::example-staging-frontend"
    error_message = "A single not_resources entry must render as a bare NotResource string."
  }

  assert {
    condition     = !contains(keys(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0]), "Action")
    error_message = "A statement built from not_actions must carry no Action key: IAM rejects a statement holding both Action and NotAction."
  }

  assert {
    condition     = !contains(keys(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement[0]), "Resource")
    error_message = "A statement built from not_resources must carry no Resource key, for the same reason."
  }
}

run "many_statements_keep_their_order_in_the_rendered_document" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "First"
        actions   = ["lambda:GetFunction"]
        resources = ["*"]
      },
      {
        sid       = "Second"
        actions   = ["logs:FilterLogEvents"]
        resources = ["*"]
      },
      {
        sid       = "Third"
        actions   = ["cloudfront:CreateInvalidation"]
        resources = ["*"]
      },
    ]
  }

  assert {
    condition     = length(jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement) == 3
    error_message = "Every supplied statement must appear in the document; a dropped statement is a permission that silently goes missing at deploy time."
  }

  assert {
    condition     = [for s in jsondecode(one(aws_iam_role_policy.this[*].policy)).Statement : s.Sid] == ["First", "Second", "Third"]
    error_message = "Statements must keep the order they were given. Both consumer estates build this list with concat, so a reordering would churn the document on every plan without changing what the role can do."
  }
}

run "a_statement_with_neither_actions_nor_not_actions_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "NoActions"
        resources = ["*"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_statement_with_both_actions_and_not_actions_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        actions     = ["s3:GetObject"]
        not_actions = ["s3:DeleteObject"]
        resources   = ["*"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_statement_with_neither_resources_nor_not_resources_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        actions = ["s3:GetObject"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_statement_with_both_resources_and_not_resources_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        actions       = ["s3:GetObject"]
        resources     = ["*"]
        not_resources = ["arn:aws:s3:::example-staging-frontend"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "an_effect_other_than_allow_or_deny_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        effect    = "allow"
        actions   = ["s3:GetObject"]
        resources = ["*"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_condition_operator_with_no_keys_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        actions   = ["sts:GetServiceBearerToken"]
        resources = ["*"]
        condition = {
          StringEquals = {}
        }
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "a_condition_key_with_no_values_is_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        actions   = ["sts:GetServiceBearerToken"]
        resources = ["*"]
        condition = {
          StringEquals = {
            "sts:AWSServiceName" = []
          }
        }
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "two_statements_sharing_a_sid_are_rejected" {
  command = plan

  variables {
    policy_statements = [
      {
        sid       = "EcrAuth"
        actions   = ["ecr:GetAuthorizationToken"]
        resources = ["*"]
      },
      {
        sid       = "EcrAuth"
        actions   = ["ecr:DescribeImages"]
        resources = ["*"]
      },
    ]
  }

  expect_failures = [var.policy_statements]
}

run "an_invalid_inline_policy_name_is_rejected" {
  command = plan

  variables {
    inline_policy_name = "deploy permissions"
  }

  expect_failures = [var.inline_policy_name]
}
