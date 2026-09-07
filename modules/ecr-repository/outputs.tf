output "repositories" {
  description = "Every repository the module created, keyed by the short domain key from var.repositories. Each value carries name, arn, url and registry_id so a consumer can reach any of them without a second lookup."
  value = {
    for key, repo in aws_ecr_repository.this : key => {
      name        = repo.name
      arn         = repo.arn
      url         = repo.repository_url
      registry_id = repo.registry_id
    }
  }
}

output "repository_urls" {
  description = "Short key to repository URL, \"<account>.dkr.ecr.<region>.amazonaws.com/<name>\". This is the map CI pushes to and a Lambda's image_uri is built from, as \"<url>:sha-<commit>\", so nothing rebuilds a registry hostname by hand."
  value       = { for key, repo in aws_ecr_repository.this : key => repo.repository_url }
}

output "repository_arns" {
  description = "Short key to repository ARN. Grant a CI push role on values(module.<name>.repository_arns)."
  value       = { for key, repo in aws_ecr_repository.this : key => repo.arn }
}

output "repository_arns_list" {
  description = "Every repository ARN as a list, sorted by key, ready to drop into an IAM policy resource list."
  value       = [for key in sort(keys(aws_ecr_repository.this)) : aws_ecr_repository.this[key].arn]
}

output "repository_names" {
  description = "Short key to full repository name, \"<name_prefix>/<key>\". The name, not the URL, is what an ECR API call takes as repositoryName."
  value       = { for key, repo in aws_ecr_repository.this : key => repo.name }
}

output "registry_id" {
  description = "The registry the repositories live in, which is the account id. Null when repositories is empty. Every repository in one module block shares it, so it is a single value rather than a map."
  value       = one(distinct([for repo in aws_ecr_repository.this : repo.registry_id]))
}
