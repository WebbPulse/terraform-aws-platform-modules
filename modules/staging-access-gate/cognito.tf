resource "aws_cognito_user_pool" "this" {
  name           = "${var.name}-access-gate"
  user_pool_tier = "ESSENTIALS"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  deletion_protection = "INACTIVE"
  mfa_configuration   = var.mfa_configuration

  dynamic "software_token_mfa_configuration" {
    for_each = var.mfa_configuration == "OFF" ? [] : [1]
    content {
      enabled = true
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true

    invite_message_template {
      email_subject = "Your staging access for ${var.cookie_domain}"
      email_message = "You have been given access to the staging site at ${local.invite_login_url}\n\nUsername: {username}\nTemporary password: {####}\n\nOpen the site, sign in with these, and choose a new password when prompted."
      sms_message   = "Staging access for ${var.cookie_domain}. Username {username}, temporary password {####}"
    }
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 3
      max_length = 254
    }
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  tags = { Name = "${var.name}-access-gate" }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.name}-gate"
  user_pool_id = aws_cognito_user_pool.this.id

  # Classic hosted UI. Managed login (version 2) needs an aws_cognito_managed_login_branding
  # style or it renders nothing, and that resource only exists in provider 6.x.
  managed_login_version = 1
}

resource "aws_cognito_user_pool_client" "login" {
  name         = "${var.name}-access-gate-login"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = local.callback_urls
  logout_urls   = local.logout_urls

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 1

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

resource "aws_cognito_user" "allowed" {
  for_each = toset([for e in var.allowed_emails : lower(e)])

  user_pool_id = aws_cognito_user_pool.this.id
  username     = each.value

  attributes = {
    email          = each.value
    email_verified = "true"
  }

  desired_delivery_mediums = ["EMAIL"]

  lifecycle {
    ignore_changes = [temporary_password, password, enabled]
  }
}
