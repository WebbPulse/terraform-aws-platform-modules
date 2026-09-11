module "codeartifact" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/codeartifact"
  version = "~> 1.8"

  domain = "webbpulse"

  repositories = {
    "pypi-store" = {
      description          = "Proxy of the public PyPI registry. Holds no first-party packages."
      external_connections = ["public:pypi"]
    }

    "npm-store" = {
      description          = "Proxy of the public npm registry. Holds no first-party packages."
      external_connections = ["public:npmjs"]
    }

    "python" = {
      description = "WebbPulse Python packages, falling through to PyPI"
      upstreams   = ["pypi-store"]
    }

    "npm" = {
      description = "WebbPulse TypeScript packages, falling through to npm"
      upstreams   = ["npm-store"]
    }

    "shared" = {
      description = "The single endpoint CI points at, for both package managers"
      upstreams   = ["python", "npm"]
    }
  }

  reader_account_ids = [
    "036807648992",
    "621554169154",
    "734702670403",
    "748861776298",
  ]

  publisher_principal_arns = [
    "arn:aws:iam::036807648992:role/webbpulse-production-github-actions-deploy",
  ]
}

output "consumer_policy_statements" {
  description = "IAM statements for a consumer account's GitHub Actions role, ready for the github-actions-role module's policy_statements input."
  value       = module.codeartifact.consumer_policy_statements
}

output "pip_index_url" {
  description = "Repository endpoint for pip. The token goes in as the password: https://aws:TOKEN@<host>/simple/"
  value       = "${module.codeartifact.endpoints["shared:pypi"]}simple/"
}

output "npm_registry_url" {
  description = "Repository endpoint for npm, for the registry line of an .npmrc."
  value       = module.codeartifact.endpoints["shared:npm"]
}

output "domain_owner" {
  description = "Account id every consumer passes as --domain-owner."
  value       = module.codeartifact.domain_owner
}
