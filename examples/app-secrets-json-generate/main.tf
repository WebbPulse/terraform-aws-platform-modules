module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 2.22"

  name_prefix = "example-production"

  secrets = {
    "app" = {
      description = "Every setting the API reads at cold start, in one blob. Flip keep to true on both generated entries once the first apply has written them, so a later version bump leaves them alone"
      version     = 1

      json = {
        SENTRY_DSN   = var.sentry_dsn
        SESSION_TTL  = "3600"
        FEATURE_FLAG = ""
      }

      json_generate = {
        mfa_master_key = {
          format = "bytes32-base64"
          keep   = false
        }

        internal_api_key = {
          format = "password"
          length = 48
          keep   = false
        }
      }
    }
  }
}

variable "sentry_dsn" {
  description = "Sentry DSN for the production project"
  type        = string
  sensitive   = true
}

output "app_secret_arn" {
  description = "ARN to hand the API as APP_SECRETS_ARN"
  value       = module.app_secrets.arns["app"]
}
