output "values" {
  description = "The parameter's live JSON object, decoded. Read keys with try, for example try(module.config.values.ses_verified_recipients, []), since a key the operator has not set yet is absent."
  value       = jsondecode(aws_ssm_parameter.this.insecure_value)

  precondition {
    condition     = can(keys(jsondecode(aws_ssm_parameter.this.insecure_value)))
    error_message = "The config parameter must hold a JSON object. Fix it with aws ssm put-parameter --overwrite."
  }
}

output "name" {
  description = "Full parameter name, the --name an operator passes to aws ssm put-parameter."
  value       = aws_ssm_parameter.this.name
}

output "arn" {
  description = "ARN of the parameter."
  value       = aws_ssm_parameter.this.arn
}

output "version" {
  description = "Parameter version Terraform last refreshed, which moves on every operator write."
  value       = aws_ssm_parameter.this.version
}
