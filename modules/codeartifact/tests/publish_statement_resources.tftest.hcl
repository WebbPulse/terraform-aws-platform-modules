provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

variables {
  domain = "example-test-domain"

  repositories = {
    "pypi-store" = {
      description          = "Proxy of the public PyPI registry."
      external_connections = ["public:pypi"]
    }
    "python" = {
      description = "First-party Python packages."
      upstreams   = ["pypi-store"]
    }
  }

  reader_account_ids       = ["036807648992", "621554169154"]
  publisher_principal_arns = ["arn:aws:iam::432410731887:role/example-test-publisher"]
}

run "publish_actions_are_split_by_resource_scope" {
  command = plan

  assert {
    condition     = tolist(local.publish_package_actions) == tolist(["codeartifact:PublishPackageVersion", "codeartifact:PutPackageMetadata"])
    error_message = "The package-scoped half must hold exactly the actions CodeArtifact requires a package resource for."
  }

  assert {
    condition     = tolist(local.publish_repository_actions) == tolist(["codeartifact:ReadFromRepository"])
    error_message = "ReadFromRepository is repository-scoped and must not be granted on a package ARN."
  }

  assert {
    condition     = length(local.repository_publish_statements["python"]) == 2
    error_message = "The publish grant must be split into a package-scoped and a repository-scoped statement."
  }

  assert {
    condition = one([
      for s in local.repository_publish_statements["python"] : s.Resource if s.Sid == "PublishRepositoryAccess"
    ]) == "*"
    error_message = "The repository-scoped half of the publish grant belongs on \"*\"."
  }

  assert {
    condition     = !contains(keys(local.repository_publish_statements), "pypi-store")
    error_message = "A store repository must never receive a publish statement."
  }
}
