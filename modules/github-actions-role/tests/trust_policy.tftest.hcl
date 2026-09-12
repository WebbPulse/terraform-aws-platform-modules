variables {
  role_name = "example-staging-github-actions-deploy"
  subjects  = ["repo:WebbPulse/ExampleRepo:*"]

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

run "the_trust_policy_is_a_web_identity_grant_on_the_github_oidc_provider" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Version == "2012-10-17"
    error_message = "The trust policy must declare the 2012-10-17 policy language version; IAM rejects a policy document without it."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "The trust policy must hold exactly one statement, so there is a single place that decides who may assume the role and no second statement that could widen it unnoticed."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "The action must be sts:AssumeRoleWithWebIdentity and nothing else: sts:AssumeRole would let an IAM principal take the role without presenting a GitHub token at all, which is the whole point of the OIDC federation."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Effect == "Allow"
    error_message = "The single trust statement must be an Allow; a Deny here would make the role unassumable by anyone."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal) == ["Federated"]
    error_message = "The principal must be Federated and only Federated: an AWS principal alongside it would open a second, non-OIDC path into the deploy role."
  }
}

run "the_conditions_are_on_the_sub_and_aud_claim_keys_github_actually_sends" {
  command = plan

  assert {
    condition     = keys(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals) == ["token.actions.githubusercontent.com:aud"]
    error_message = "The audience must be pinned with StringEquals on the key token.actions.githubusercontent.com:aud. A misspelt condition key is not an error to IAM, it is simply a condition that never matches anything, so the whole restriction silently disappears."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike) == ["token.actions.githubusercontent.com:sub"]
    error_message = "The subject must be matched with StringLike on the key token.actions.githubusercontent.com:sub, because the subject claims this estate uses carry wildcards. A wrong key here would leave every GitHub repository in the world able to assume the role."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "The audience must default to sts.amazonaws.com, which is what aws-actions/configure-aws-credentials requests; any other value makes every workflow fail to assume the role."
  }

  assert {
    condition     = length(keys(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition)) == 2
    error_message = "The condition block must hold exactly the StringEquals audience check and the StringLike subject check. An extra operator is either dead weight or an unreviewed loosening of the two checks that matter."
  }
}

run "a_single_subject_renders_as_a_bare_string_rather_than_a_one_element_list" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] == "repo:WebbPulse/ExampleRepo:*"
    error_message = "A single subject must render as a bare JSON string, not a one element array. IAM treats the two identically, but the console and every diff of this role show the bare string, so rendering a list would produce a spurious change on every plan for roles that already exist."
  }

  assert {
    condition     = can(tostring(local.trust_subjects))
    error_message = "local.trust_subjects must collapse to a string when there is exactly one subject; that collapse is what keeps the rendered document stable against the roles already deployed."
  }
}

run "several_subjects_render_as_a_list_so_each_one_is_matched_independently" {
  command = plan

  variables {
    subjects = [
      "repo:WebbPulse/ExampleRepo:pull_request",
      "repo:WebbPulse/ExampleRepo:ref:refs/heads/staging",
      "repo:WebbPulse/ExampleRepo:ref:refs/heads/main",
    ]
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"]) == 3
    error_message = "Three subjects must render as a three element array. StringLike is an OR across the values, which is what lets the CI role admit pull requests and two branches without three separate roles."
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] == [
      "repo:WebbPulse/ExampleRepo:pull_request",
      "repo:WebbPulse/ExampleRepo:ref:refs/heads/staging",
      "repo:WebbPulse/ExampleRepo:ref:refs/heads/main",
    ]
    error_message = "The subjects must appear in the order they were given and be passed through verbatim. Sorting or rewriting them would churn the rendered document against the deployed roles for no behavioural gain."
  }
}

run "the_rename_proof_immutable_subject_form_is_accepted_verbatim" {
  command = plan

  variables {
    subjects = [
      "repo:WebbPulse@185014056/ExampleRepo@1029410045:environment:staging",
      "repo:WebbPulse@185014056/ExampleRepo@1029410045:environment:production",
    ]
  }

  assert {
    condition = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] == [
      "repo:WebbPulse@185014056/ExampleRepo@1029410045:environment:staging",
      "repo:WebbPulse@185014056/ExampleRepo@1029410045:environment:production",
    ]
    error_message = "Newer repositories in this organisation are issued immutable subject claims of the form repo:ORG@ORG_ID/REPO@REPO_ID:..., and the module must pass the @ and the numeric ids through untouched. Any normalisation of the string would produce a subject that never matches the token GitHub actually presents, and the workflow would fail to assume the role with a bare AccessDenied that names no claim."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"]) == 2
    error_message = "Both immutable subjects must survive into the document: an environment bound subject admits only jobs bound to that GitHub environment, so dropping one silently removes a deploy path."
  }
}

run "both_subject_shapes_can_be_mixed_on_one_role_during_a_migration" {
  command = plan

  variables {
    subjects = [
      "repo:WebbPulse/ExampleRepo:*",
      "repo:WebbPulse@185014056/ExampleRepo@1029410045:*",
    ]
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"]) == 2
    error_message = "A repository being moved onto immutable subjects needs both shapes trusted at once for the window in which either may be presented, so the module must never treat the two forms as mutually exclusive."
  }
}

run "a_non_default_audience_reaches_the_trust_policy" {
  command = plan

  variables {
    audience = "example-sts-audience"
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "example-sts-audience"
    error_message = "An overridden audience must reach the trust policy, or the role keeps trusting sts.amazonaws.com while the workflow presents a different aud and every assume call fails."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition.StringEquals) == ["token.actions.githubusercontent.com:aud"]
    error_message = "Overriding the audience must not move the check onto a different condition key: it is still the aud claim that is being pinned."
  }
}

run "an_empty_subject_list_is_rejected" {
  command = plan

  variables {
    subjects = []
  }

  expect_failures = [var.subjects]
}

run "a_subject_that_is_not_a_repo_claim_is_rejected" {
  command = plan

  variables {
    subjects = ["WebbPulse/ExampleRepo:*"]
  }

  expect_failures = [var.subjects]
}

run "a_repo_subject_with_no_claim_segment_is_rejected" {
  command = plan

  variables {
    subjects = ["repo:WebbPulse/ExampleRepo"]
  }

  expect_failures = [var.subjects]
}

run "a_duplicated_subject_is_rejected" {
  command = plan

  variables {
    subjects = [
      "repo:WebbPulse/ExampleRepo:*",
      "repo:WebbPulse/ExampleRepo:*",
    ]
  }

  expect_failures = [var.subjects]
}

run "an_empty_audience_is_rejected" {
  command = plan

  variables {
    audience = ""
  }

  expect_failures = [var.audience]
}
