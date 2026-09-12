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

run "the_provider_is_created_by_default_for_the_github_token_issuer" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.this) == 1
    error_message = "create_oidc_provider defaults to true, so the first stack in an account gets the provider without extra wiring."
  }

  assert {
    condition     = one(aws_iam_openid_connect_provider.this[*].url) == "https://token.actions.githubusercontent.com"
    error_message = "The provider URL must be exactly https://token.actions.githubusercontent.com: it is the issuer in GitHub's token, and AWS matches the iss claim against this URL before any condition in the trust policy is considered."
  }

  assert {
    condition     = local.oidc_provider_url == "https://token.actions.githubusercontent.com"
    error_message = "The issuer URL must stay a module constant rather than an input, because an account holds at most one provider per URL and a typo would create a second, useless one instead of failing."
  }
}

run "the_default_thumbprints_are_the_pair_both_estates_were_created_with" {
  command = plan

  assert {
    condition     = length(one(aws_iam_openid_connect_provider.this[*].thumbprint_list)) == 2
    error_message = "The default thumbprint list must keep both entries. AWS verifies GitHub's tokens against its own trusted CA store, so these are informational, but dropping one changes the resource in place and produces a diff on every existing provider in the estate."
  }

  assert {
    condition     = var.oidc_thumbprints[0] == "6938fd4d98bab03faadb97b34396831e3780aea1"
    error_message = "The first default thumbprint must stay 6938fd4d98bab03faadb97b34396831e3780aea1, which is what the providers in both estates were created with, so that adopting an existing provider into this module plans clean rather than showing an update."
  }

  assert {
    condition     = var.oidc_thumbprints[1] == "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
    error_message = "The second default thumbprint must stay 1c58a3a8518e8759bf075b76b750d4f2df264fcd, for the same reason the first must: the pair and its order are what the deployed providers already hold."
  }

  assert {
    condition = alltrue([
      for t in var.oidc_thumbprints : contains(one(aws_iam_openid_connect_provider.this[*].thumbprint_list), t)
    ])
    error_message = "Every configured thumbprint must reach the provider resource, since the resource requires the list even though AWS no longer verifies against it."
  }
}

run "the_provider_can_be_supplied_from_outside_for_a_second_role_in_the_account" {
  command = plan

  variables {
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.this) == 0
    error_message = "An account holds at most one OIDC provider per URL, so the second module block in the same account must create none. Creating it twice is an EntityAlreadyExists failure at apply time, after the plan looked clean."
  }

  assert {
    condition     = local.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "With creation off, the passed ARN must become the provider ARN the module uses; otherwise the trust policy is built against a null principal."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "The passed provider ARN must be the Federated principal in the trust policy. This is exactly how the CI role in both consumer estates is wired: it takes oidc_provider_arn from the deploy role's output rather than creating a second provider."
  }

  assert {
    condition     = output.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "The oidc_provider_arn output must pass a supplied ARN straight back out, so a chain of module blocks can keep handing the same provider along without any caller knowing which block created it."
  }
}

run "a_created_provider_is_still_the_trust_principal_and_reaches_the_output" {
  command = plan

  override_resource {
    target          = aws_iam_openid_connect_provider.this
    override_during = plan
    values = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  assert {
    condition     = local.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "When the provider is created here its own ARN must become the one the module uses, so the role and the provider it trusts can never drift apart."
  }

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "The created provider must be the Federated principal; anything else leaves a role that trusts a provider which does not exist, and every workflow fails the assume call."
  }

  assert {
    condition     = output.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "The oidc_provider_arn output must expose the provider created here, because that is how the second module block in the same account, the CI role in both consumer estates, gets an ARN to pass back in with create_oidc_provider set to false."
  }
}

run "turning_creation_off_without_an_arn_is_rejected" {
  command = plan

  variables {
    create_oidc_provider = false
    oidc_provider_arn    = null
  }

  expect_failures = [var.oidc_provider_arn]
}

run "an_oidc_provider_arn_for_a_different_issuer_is_rejected" {
  command = plan

  variables {
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.example.com"
  }

  expect_failures = [var.oidc_provider_arn]
}

run "a_thumbprint_that_is_not_a_forty_character_hex_digest_is_rejected" {
  command = plan

  variables {
    oidc_thumbprints = ["not-a-thumbprint"]
  }

  expect_failures = [var.oidc_thumbprints]
}

run "an_uppercase_thumbprint_is_rejected" {
  command = plan

  variables {
    oidc_thumbprints = ["6938FD4D98BAB03FAADB97B34396831E3780AEA1"]
  }

  expect_failures = [var.oidc_thumbprints]
}

run "an_empty_thumbprint_list_is_rejected" {
  command = plan

  variables {
    oidc_thumbprints = []
  }

  expect_failures = [var.oidc_thumbprints]
}

run "more_than_five_thumbprints_are_rejected" {
  command = plan

  variables {
    oidc_thumbprints = [
      "6938fd4d98bab03faadb97b34396831e3780aea1",
      "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "cccccccccccccccccccccccccccccccccccccccc",
      "dddddddddddddddddddddddddddddddddddddddd",
    ]
  }

  expect_failures = [var.oidc_thumbprints]
}
