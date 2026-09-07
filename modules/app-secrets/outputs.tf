output "arns" {
  description = "ARN of each secret, keyed the same as the secrets input. Pass one to an application as the env var it reads at cold start, for example APP_SECRETS_ARN."
  value       = local.secret_arns
}

output "names" {
  description = "Full Secrets Manager name of each secret, keyed the same as the secrets input. This is the secret-id an operator passes to aws secretsmanager put-secret-value."
  value       = { for k, r in aws_secretsmanager_secret.this : k => r.name }
}

output "ids" {
  description = "Secrets Manager id of each secret, keyed the same as the secrets input. The provider returns the ARN here; the field exists so a consumer that referenced .id on a hand-written resource does not have to change which attribute it reads."
  value       = { for k, r in aws_secretsmanager_secret.this : k => r.id }
}

output "version_ids" {
  description = "Version id of each Terraform-managed version, keyed the same as the secrets input. A secret populated out of band, and a placeholder after an operator has overwritten it, is absent or stale here; nothing should depend on this beyond forcing ordering."
  value = merge(
    { for k, r in aws_secretsmanager_secret_version.this : k => r.version_id },
    { for k, r in aws_secretsmanager_secret_version.placeholder : k => r.version_id },
  )
}

output "read_policy_json" {
  description = "An IAM policy document granting policy_actions on exactly the secrets in policy_secret_keys, ready to attach to the role that reads them: policy = module.app_secrets.read_policy_json on an aws_iam_role_policy, or one statement among several via read_policy_statement."
  value       = local.read_policy_json
}

output "read_policy_statement" {
  description = "The single statement of read_policy_json as an object, for a consumer composing one inline policy out of several statements, for example the policy_statements input of the github-actions-role module or a hand-built jsonencode."
  value       = local.policy_statement
}

output "policy_resources" {
  description = "The secret ARNs the read policy covers, sorted. Use it to build a policy by hand when the module's shape does not fit."
  value       = local.policy_resources
}
