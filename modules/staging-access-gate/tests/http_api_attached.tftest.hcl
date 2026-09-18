variables {
  name           = "example-attach"
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

run "default_derives_the_authorizer_from_the_api_id" {
  command = plan

  variables {
    http_api_id = "abcd1234ef"
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.origin_verify) == 1 && length(aws_lambda_permission.authorizer) == 1
    error_message = "Leaving http_api_attached null must keep the historic behaviour: a non null http_api_id creates the authorizer and its invoke permission."
  }
}

run "default_creates_nothing_without_an_api_id" {
  command = plan

  assert {
    condition     = length(aws_apigatewayv2_authorizer.origin_verify) == 0 && length(aws_lambda_permission.authorizer) == 0
    error_message = "A gate used for CloudFront only passes no http_api_id and must still get no gateway authorizer."
  }
}

run "attached_false_suppresses_the_authorizer_despite_an_api_id" {
  command = plan

  variables {
    http_api_id       = "abcd1234ef"
    http_api_attached = false
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.origin_verify) == 0 && length(aws_lambda_permission.authorizer) == 0
    error_message = "http_api_attached false must win over a non null http_api_id, so a consumer can hold the attachment back for an apply."
  }
}

run "attached_true_plans_the_authorizer_from_a_known_boolean" {
  command = plan

  variables {
    http_api_id       = "abcd1234ef"
    http_api_attached = true
  }

  assert {
    condition     = length(aws_apigatewayv2_authorizer.origin_verify) == 1 && length(aws_lambda_permission.authorizer) == 1
    error_message = "http_api_attached true must plan the authorizer, which is what lets a fresh account create the API and attach the gate in one apply."
  }
}
