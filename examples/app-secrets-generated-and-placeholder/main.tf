module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 2.22"

  name_prefix = "example-production"

  recovery_window_in_days = 7

  secrets = {
    "secret-key" = {
      description     = "Session signing key, generated here and never read back"
      generate        = true
      generate_length = 64
      version         = 1
    }

    "admin-username" = {
      description = "Bootstrap admin username, set out of band after the first apply"
      placeholder = "REPLACE_ME"
      version     = 1
    }

    "admin-password" = {
      description = "Bootstrap admin password, set out of band after the first apply"
      placeholder = "REPLACE_ME"
      version     = 1
    }

    "admin-email" = {
      description = "Bootstrap admin email, set out of band after the first apply"
      placeholder = "REPLACE_ME"
      version     = 1
    }

    "sentry-dsn" = {
      description             = "Sentry DSN, populated after the Sentry project is created"
      recovery_window_in_days = 0
    }
  }
}

resource "aws_iam_role" "api" {
  name = "example-production-api"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "api_secrets" {
  name   = "app-secrets"
  role   = aws_iam_role.api.id
  policy = module.app_secrets.read_policy_json
}

output "secret_names" {
  description = "Secret ids to pass to aws secretsmanager put-secret-value when seeding the real values"
  value       = module.app_secrets.names
}
