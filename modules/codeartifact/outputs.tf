output "domain" {
  description = "Name of the domain. Pass it to aws codeartifact commands as --domain."
  value       = aws_codeartifact_domain.this.domain
}

output "domain_owner" {
  description = "AWS account id owning the domain. A caller authenticated to any other account must pass this as --domain-owner, because domain names are only unique within an account."
  value       = aws_codeartifact_domain.this.owner
}

output "domain_arn" {
  description = "ARN of the domain. This is the resource a consumer's own IAM policy names for codeartifact:GetAuthorizationToken."
  value       = aws_codeartifact_domain.this.arn
}

output "repository_arns" {
  description = "ARN of each repository, keyed the same as the repositories input. These are the resources a consumer's own IAM policy names for the repository-level read actions."
  value       = local.repository_arns
}

output "repository_names" {
  description = "Name of each repository, keyed the same as the repositories input. Same strings as the map keys; the output exists so a consumer never has to hard-code one."
  value       = { for k, r in local.repositories : k => r.repository }
}

output "endpoints" {
  description = "Repository endpoint URL for every repository and every format in endpoint_formats, keyed \"<repository>:<format>\", for example \"shared:pypi\". This is the URL pip's index-url and npm's registry point at, with the authorization token as the password."
  value       = { for k, d in data.aws_codeartifact_repository_endpoint.this : k => d.repository_endpoint }
}

output "consumer_resource_arns" {
  description = "The ARNs a consumer's own reader role policy needs, as an object with domain and repositories. codeartifact:GetAuthorizationToken is granted on domain; every repository-level read action is granted on repositories. sts:GetServiceBearerToken goes alongside them on Resource \"*\", and is the piece most often forgotten."
  value = {
    domain       = aws_codeartifact_domain.this.arn
    repositories = sort(values(local.repository_arns))
  }
}

output "consumer_policy_statements" {
  description = "A ready-made pair of IAM statements for a consumer's own role: codeartifact read on this domain and its repositories, plus sts:GetServiceBearerToken. Feed it straight to the github-actions-role module's policy_statements input, or jsonencode it into an aws_iam_role_policy. The grant is only half of the pair; the domain and repository policies here are the other half."
  value = [
    {
      Sid      = "CodeArtifactToken"
      Effect   = "Allow"
      Action   = ["codeartifact:GetAuthorizationToken"]
      Resource = [aws_codeartifact_domain.this.arn]
    },
    {
      Sid      = "CodeArtifactRead"
      Effect   = "Allow"
      Action   = sort(distinct(var.reader_repository_actions))
      Resource = sort(values(local.repository_arns))
    },
    {
      Sid      = "CodeArtifactBearerToken"
      Effect   = "Allow"
      Action   = ["sts:GetServiceBearerToken"]
      Resource = ["*"]
      Condition = {
        StringEquals = {
          "sts:AWSServiceName" = "codeartifact.amazonaws.com"
        }
      }
    },
  ]
}
