output "configuration_set_name" {
  description = "Name of the configuration set every send names, and the name reputation metrics are published under."
  value       = aws_sesv2_configuration_set.this.configuration_set_name
}

output "configuration_set_arn" {
  description = "ARN of the configuration set, for the ses:SendEmail grant on the sending role."
  value       = aws_sesv2_configuration_set.this.arn
}

output "identity_arn" {
  description = "ARN of the sending identity, whether it is the domain or the single sender address."
  value       = local.sending_identity_arn
}

output "identity_name" {
  description = "The verified sending identity itself, the domain or the sender address."
  value       = var.domain == null ? var.sender_address : var.domain
}

output "dkim_tokens" {
  description = "Easy DKIM tokens SES issued for the domain, each published as a CNAME at <token>._domainkey.<domain>. Empty on a sender address identity."
  value       = var.domain == null ? [] : aws_sesv2_email_identity.domain[0].dkim_signing_attributes[0].tokens
}

output "mail_from_domain" {
  description = "Custom MAIL FROM subdomain in force, null when the SES default is used."
  value       = local.mail_from_count == 1 ? var.mail_from_domain : null
}

output "send_policy_statements" {
  description = "IAM statement list granting ses:SendEmail on this identity through this configuration set, ready to merge into a sending role's policy."
  value = [{
    Sid    = "SendEmailThroughTheConfigurationSet"
    Effect = "Allow"
    Action = ["ses:SendEmail"]
    Resource = [
      local.sending_identity_arn,
      aws_sesv2_configuration_set.this.arn,
    ]
  }]
}

output "send_policy_json" {
  description = "The same grant as a complete IAM policy document."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "SendEmailThroughTheConfigurationSet"
      Effect = "Allow"
      Action = ["ses:SendEmail"]
      Resource = [
        local.sending_identity_arn,
        aws_sesv2_configuration_set.this.arn,
      ]
    }]
  })
}

output "verified_recipient_arns" {
  description = "ARNs of the recipient identities created from verified_recipients, keyed by address."
  value       = { for address, identity in aws_sesv2_email_identity.recipient : address => identity.arn }
}
