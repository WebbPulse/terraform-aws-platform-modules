module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 2.30"

  name_prefix = "example-production"

  secrets = {
    "app" = {
      description             = "Every setting the API reads at cold start. OAuth client secrets and the like are put by an operator and survive a version bump"
      version                 = 1
      json_preserve_unmanaged = true

      json = {
        SESSION_TTL = "3600"
      }

      json_generate = {
        mfa_master_key = {
          format = "bytes32-base64"
          keep   = true
        }
      }
    }
  }
}

output "app_secret_name" {
  description = "Secret id an operator passes to put-secret-value, carrying every key"
  value       = module.app_secrets.names["app"]
}
