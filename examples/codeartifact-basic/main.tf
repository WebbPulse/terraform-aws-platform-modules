# The shape the WebbPulse estate runs: one domain in the platform account, a store repository per
# package format holding the external connection to the public registry, an internal repository per
# format for first-party packages, and one fan-in repository so every CI job points at a single
# endpoint per package manager.
#
#   pypi-store  external connection -> public:pypi
#   npm-store   external connection -> public:npmjs
#   python      upstream -> pypi-store
#   npm         upstream -> npm-store
#   shared      upstream -> python, npm
#
# A pip install against shared walks shared -> python -> pypi-store and out to PyPI, caching every
# asset it fetches on the way back. Storage is billed once per domain, so the cached wheel is paid
# for once no matter how many repositories it is visible in.

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

  # The four application accounts. Naming the CI role ARNs rather than the account roots would be
  # tighter still; reader_principal_arns takes them once the roles exist.
  reader_account_ids = [
    "036807648992", # Portfolio production
    "621554169154", # Portfolio staging
    "734702670403", # CarModPicker production
    "748861776298", # CarModPicker staging
  ]

  # The role that publishes first-party packages. It reaches python and npm, and never the two
  # store repositories: a first-party package published into pypi-store would shadow the public
  # package of the same name for everything downstream of it.
  publisher_principal_arns = [
    "arn:aws:iam::036807648992:role/webbpulse-production-github-actions-deploy",
  ]
}

# What a consumer account attaches to its own CI role. Both halves are required: the domain and
# repository policies inside the module allow the account in, and this allows the role out.
output "consumer_policy_statements" {
  description = "IAM statements for a consumer account's GitHub Actions role, ready for the github-actions-role module's policy_statements input."
  value       = module.codeartifact.consumer_policy_statements
}

# The URLs pip and npm point at. Only the shared entries are needed in normal use; the rest are
# there for a job that deliberately wants to bypass the fan-in.
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
