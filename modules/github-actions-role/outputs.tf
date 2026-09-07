output "role_arn" {
  description = "ARN of the deploy role. Set it as the AWS_DEPLOY_ROLE_ARN variable on the GitHub environment and pass it to aws-actions/configure-aws-credentials as role-to-assume."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the deploy role, for aws_iam_role_policy_attachment or extra aws_iam_role_policy resources outside this module."
  value       = aws_iam_role.this.name
}

output "oidc_provider_arn" {
  description = "ARN of the token.actions.githubusercontent.com OIDC provider the role trusts, whether created here or passed in."
  value       = local.oidc_provider_arn
}
