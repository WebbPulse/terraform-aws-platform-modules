module "config" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/operator-config"
  version = "~> 2.30"

  name_prefix = "example-staging"
}

output "config_parameter_name" {
  description = "Parameter an operator writes with aws ssm put-parameter --overwrite"
  value       = module.config.name
}

output "ses_verified_recipients" {
  description = "Recipients to hand ses-identity, empty until an operator sets them"
  value       = try(module.config.values.ses_verified_recipients, [])
}
