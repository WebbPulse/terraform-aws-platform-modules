# The other two shapes: a value Terraform generates and stores, and a value Terraform must never
# learn. This is what an estate looks like after it moves off SSM SecureString parameters, where a
# generated signing key sat next to three admin credentials seeded as REPLACE_ME and edited by hand.
#
# The generated key is created once and stays put; nothing reads it back out of state. The
# placeholders are seeded once, then an operator overwrites each with
#   aws secretsmanager put-secret-value --secret-id example-production/admin-password ...
# and ignore_changes keeps Terraform from planning the placeholder back over it.

module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 1.6"

  name_prefix = "example-production"

  # A recoverable window on credentials that are not trivially regenerated. Secrets whose name is
  # reused right after a destroy need 0 instead, because Secrets Manager refuses to reuse the name
  # of a secret still scheduled for deletion.
  recovery_window_in_days = 7

  secrets = {
    "secret-key" = {
      description     = "Session signing key, generated here and never read back"
      generate        = true
      generate_length = 64
    }

    "admin-username" = {
      description = "Bootstrap admin username, set out of band after the first apply"
      placeholder = "REPLACE_ME"
    }

    "admin-password" = {
      description = "Bootstrap admin password, set out of band after the first apply"
      placeholder = "REPLACE_ME"
    }

    "admin-email" = {
      description = "Bootstrap admin email, set out of band after the first apply"
      placeholder = "REPLACE_ME"
    }

    # No value at all: the secret exists so the IAM grant is stable, and the first
    # put-secret-value creates version 1.
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

# One statement covering all five secrets, because this application reads each on its own.
resource "aws_iam_role_policy" "api_secrets" {
  name   = "app-secrets"
  role   = aws_iam_role.api.id
  policy = module.app_secrets.read_policy_json
}

output "secret_names" {
  description = "Secret ids to pass to aws secretsmanager put-secret-value when seeding the real values"
  value       = module.app_secrets.names
}
