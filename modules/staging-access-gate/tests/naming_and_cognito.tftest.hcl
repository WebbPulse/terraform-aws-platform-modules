variables {
  name           = "example-staging"
  cookie_domain  = "staging.example.com"
  site_host      = "www.staging.example.com"
  allowed_emails = ["owner@example.com"]
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

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

run "every_resource_is_named_from_the_one_name_input" {
  command = plan

  assert {
    condition     = aws_cognito_user_pool.this.name == "example-staging-access-gate"
    error_message = "The user pool must be named <name>-access-gate so two gates in one account, for two applications, never collide on a name."
  }

  assert {
    condition     = aws_cognito_user_pool_domain.this.domain == "example-staging-gate"
    error_message = "The hosted UI domain prefix must be <name>-gate. It is globally unique across all of Cognito in the region, so it has to be derived from the application prefix rather than a fixed string."
  }

  assert {
    condition     = aws_lambda_function.login.function_name == "example-staging-access-gate-login" && aws_lambda_function.authorizer.function_name == "example-staging-access-gate-authorizer"
    error_message = "Both Lambdas must be named from name, because the login function name is an output consumers grant invoke on and the authorizer name is how a responder finds the right logs."
  }

  assert {
    condition     = aws_cloudwatch_log_group.login.name == "/aws/lambda/example-staging-access-gate-login" && aws_cloudwatch_log_group.authorizer.name == "/aws/lambda/example-staging-access-gate-authorizer"
    error_message = "Each log group name must be /aws/lambda/ plus the exact function name. Lambda writes to that path and no other, so a mismatch means the module manages an empty group while the real logs are created with never expiring retention."
  }

  assert {
    condition     = aws_ssm_parameter.signing_key.name == "/example-staging/access-gate/signing-private-key" && aws_ssm_parameter.client_secret.name == "/example-staging/access-gate/cognito-client-secret" && aws_ssm_parameter.origin_verify.name == "/example-staging/access-gate/origin-verify"
    error_message = "All three parameters must live under /<name>/access-gate/, which is the prefix the Lambda role policies are written against and the prefix a second application's gate cannot reach."
  }

  assert {
    condition     = aws_cloudfront_key_group.signing.name == "example-staging-access-gate" && aws_cloudfront_public_key.signing.name == "example-staging-access-gate"
    error_message = "The key group and public key must be named from name: CloudFront requires both names to be unique per account, so a fixed name would let one staging environment break another."
  }

  assert {
    condition     = aws_cloudfront_function.gate.name == "example-staging-access-gate"
    error_message = "The viewer-request function name must be derived from name, since CloudFront function names are account unique and the consuming distribution references this one by ARN."
  }
}

run "all_three_secrets_are_encrypted_parameters_rather_than_plain_strings" {
  command = plan

  assert {
    condition     = aws_ssm_parameter.signing_key.type == "SecureString"
    error_message = "The cookie signing private key must be a SecureString. Anyone who reads it can mint a signed cookie for any path and walk straight past the gate, so it must never sit in plaintext in Parameter Store."
  }

  assert {
    condition     = aws_ssm_parameter.client_secret.type == "SecureString"
    error_message = "The Cognito client secret must be a SecureString: it is half of what the code exchange authenticates with."
  }

  assert {
    condition     = aws_ssm_parameter.origin_verify.type == "SecureString"
    error_message = "The origin verification value must be a SecureString, because it is the single shared secret that distinguishes a request CloudFront proxied from one an attacker sent straight at the API hostname."
  }

  assert {
    condition     = tls_private_key.signing.algorithm == "RSA" && tls_private_key.signing.rsa_bits == 2048
    error_message = "CloudFront signed cookies are verified against an RSA public key, and 2048 bits is the size CloudFront accepts; an EC key or a shorter modulus is rejected outright when the public key is uploaded."
  }

  assert {
    condition     = random_password.origin_verify.special == false && random_password.origin_verify.length == 48
    error_message = "The origin verification value travels as an HTTP header, so it must be long enough to be unguessable and free of characters that would need header encoding."
  }
}

run "the_user_pool_is_invite_only_and_cannot_be_signed_up_to" {
  command = plan

  assert {
    condition     = aws_cognito_user_pool.this.admin_create_user_config[0].allow_admin_create_user_only
    error_message = "Self sign-up must be off. The gate exists to keep an unreleased staging site private, and a pool anyone can register with is not a gate at all."
  }

  assert {
    condition     = tolist(aws_cognito_user_pool.this.username_attributes) == tolist(["email"])
    error_message = "The username must be the email address, because allowed_emails is the allow list and the login handler matches the id token's email claim against it."
  }

  assert {
    condition     = aws_cognito_user_pool.this.password_policy[0].minimum_length >= 12
    error_message = "A twelve character minimum is the floor here: these accounts are handed out by email invitation and are the only thing standing between the public internet and an unreleased site."
  }

  assert {
    condition     = aws_cognito_user_pool_client.login.prevent_user_existence_errors == "ENABLED"
    error_message = "User existence errors must be suppressed so the hosted UI cannot be used to enumerate which addresses have staging access."
  }

  assert {
    condition     = aws_cognito_user_pool_client.login.generate_secret
    error_message = "The app client must have a secret. The login Lambda is a confidential client doing a server side code exchange, and a public client would let anyone who knows the client id complete the flow."
  }

  assert {
    condition     = tolist(aws_cognito_user_pool_client.login.allowed_oauth_flows) == tolist(["code"])
    error_message = "Only the authorization code flow may be allowed: the implicit flow would put tokens in the URL fragment where the browser history and any redirect logging keeps them."
  }

  assert {
    condition     = aws_cognito_user_pool.this.mfa_configuration == "OFF" && length(aws_cognito_user_pool.this.software_token_mfa_configuration) == 0
    error_message = "mfa_configuration defaults to OFF, and with it off no software token block may be rendered, because Cognito rejects a pool that configures a factor it does not use."
  }
}

run "turning_mfa_on_enables_the_software_token_factor" {
  command = plan

  variables {
    mfa_configuration = "ON"
  }

  assert {
    condition     = aws_cognito_user_pool.this.mfa_configuration == "ON"
    error_message = "mfa_configuration must reach the pool so an environment holding anything sensitive can require a second factor."
  }

  assert {
    condition     = one(aws_cognito_user_pool.this.software_token_mfa_configuration).enabled
    error_message = "Setting MFA to ON without enabling a factor would leave every user unable to complete sign-in, so the software token factor must be enabled alongside it."
  }
}

run "one_cognito_user_is_created_per_allowed_email_case_folded" {
  command = plan

  variables {
    allowed_emails = ["Owner@Example.com", "second@example.com"]
  }

  assert {
    condition     = length(aws_cognito_user.allowed) == 2
    error_message = "Every address in allowed_emails must become a user: the pool is invite only, so an address with no user is an address that can never sign in."
  }

  assert {
    condition     = aws_cognito_user.allowed["owner@example.com"].username == "owner@example.com"
    error_message = "Usernames must be lower cased. Cognito treats the username as case sensitive while people type their address however they like, so an invitation to Owner@Example.com would leave owner@example.com locked out."
  }

  assert {
    condition     = aws_cognito_user.allowed["owner@example.com"].attributes["email_verified"] == "true"
    error_message = "The email must be pre-verified: the address is what the invitation was sent to, and leaving it unverified adds a verification step the invited user cannot complete."
  }

  assert {
    condition     = aws_cognito_user.allowed["second@example.com"].username == "second@example.com"
    error_message = "A second address must get its own user keyed on the folded address, since the resource is indexed by that string and two entries differing only in case would collide on one Cognito username."
  }
}

run "the_callback_and_logout_urls_cover_every_host_the_distribution_serves" {
  command = plan

  variables {
    additional_hosts = ["staging.example.com"]
  }

  assert {
    condition     = aws_cognito_user_pool_client.login.callback_urls == toset(["https://www.staging.example.com/_auth/callback", "https://staging.example.com/_auth/callback"])
    error_message = "Both consumers serve an apex and a www host from one distribution, and Cognito refuses a redirect_uri that is not registered exactly, so every host must have a callback URL built from the auth prefix."
  }

  assert {
    condition     = aws_cognito_user_pool_client.login.logout_urls == toset(["https://www.staging.example.com/_auth/logged-out", "https://staging.example.com/_auth/logged-out"])
    error_message = "Every host needs a logout URL too, otherwise signing out from the apex lands on a Cognito error page instead of the site."
  }

  assert {
    condition     = length(aws_cognito_user_pool_client.login.callback_urls) == 2
    error_message = "Exactly one callback URL per host must be registered. A duplicate would be harmless but a missing one is a redirect_uri mismatch error the viewer can do nothing about."
  }
}

run "the_invite_email_points_at_the_site_rather_than_the_hosted_ui" {
  command = plan

  assert {
    condition     = strcontains(aws_cognito_user_pool.this.admin_create_user_config[0].invite_message_template[0].email_message, "https://www.staging.example.com/")
    error_message = "invite_login_url defaults to https://<site_host>/ so an invited user lands on the site and is carried through Cognito by the gate, rather than on a hosted UI page that redirects nowhere useful."
  }

  assert {
    condition     = strcontains(aws_cognito_user_pool.this.admin_create_user_config[0].invite_message_template[0].email_subject, "staging.example.com")
    error_message = "The subject must name the domain: a person with access to several staging environments needs to tell the invitations apart."
  }
}

run "an_explicit_invite_login_url_replaces_the_derived_one" {
  command = plan

  variables {
    invite_login_url = "https://www.staging.example.com/welcome"
  }

  assert {
    condition     = strcontains(aws_cognito_user_pool.this.admin_create_user_config[0].invite_message_template[0].email_message, "https://www.staging.example.com/welcome")
    error_message = "invite_login_url must win over the derived default, since a site whose entry point is not the bare root needs the invitation to point there."
  }
}

run "a_name_containing_cognito_is_rejected" {
  command = plan

  variables {
    name = "example-cognito-staging"
  }

  expect_failures = [var.name]
}

run "a_name_containing_aws_is_rejected" {
  command = plan

  variables {
    name = "example-aws-staging"
  }

  expect_failures = [var.name]
}

run "a_name_with_uppercase_is_rejected" {
  command = plan

  variables {
    name = "Example-Staging"
  }

  expect_failures = [var.name]
}

run "a_cookie_domain_with_a_leading_dot_is_rejected" {
  command = plan

  variables {
    cookie_domain = ".staging.example.com"
    site_host     = "staging.example.com"
  }

  expect_failures = [var.cookie_domain]
}

run "a_cookie_domain_that_is_the_www_host_is_rejected" {
  command = plan

  variables {
    cookie_domain = "www.staging.example.com"
    site_host     = "www.staging.example.com"
  }

  expect_failures = [var.cookie_domain]
}

run "a_site_host_outside_the_cookie_domain_is_rejected" {
  command = plan

  variables {
    site_host = "www.staging.other-example.com"
  }

  expect_failures = [var.site_host]
}

run "an_empty_allowed_emails_list_is_rejected" {
  command = plan

  variables {
    allowed_emails = []
  }

  expect_failures = [var.allowed_emails]
}

run "an_allowed_emails_entry_that_is_not_an_address_is_rejected" {
  command = plan

  variables {
    allowed_emails = ["owner"]
  }

  expect_failures = [var.allowed_emails]
}

run "the_same_address_twice_in_different_cases_is_rejected" {
  command = plan

  variables {
    allowed_emails = ["owner@example.com", "Owner@example.com"]
  }

  expect_failures = [var.allowed_emails]
}

run "an_unknown_mfa_configuration_is_rejected" {
  command = plan

  variables {
    mfa_configuration = "REQUIRED"
  }

  expect_failures = [var.mfa_configuration]
}
