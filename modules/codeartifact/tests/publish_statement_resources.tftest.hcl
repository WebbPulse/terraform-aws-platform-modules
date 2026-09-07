# The publish grant's Resource, which CodeArtifact validates and Terraform cannot.
#
# codeartifact:PublishPackageVersion is a package-level action: the user guide says outright that
# "the resource used with this action must be a package", and the same page's NuGet note tells a
# publisher to add ReadFromRepository "and specify the repository resource". Granting the whole set
# on Resource "*" in one statement is rejected at apply time with
#
#     ValidationException: Policy document isn't a valid policy document
#
# which no plan can catch, because it is the service validating rather than Terraform. So the module
# splits the publish grant: the package-scoped actions onto the repository's package ARN, and
# anything else onto "*".
#
# Publisher ARNs are literals here, unlike unknown_publisher_arns.tftest.hcl, precisely so the
# rendered policy is known at plan time and the Resource values can be asserted on.

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

  # The package ARN derives from the repository resource, so it and the policy JSON that embeds it
  # are unknown until apply and cannot be asserted on in a plan-only run. What is knowable, and what
  # actually went wrong, is the split itself: which actions are treated as package-scoped.
  assert {
    condition     = tolist(local.publish_package_actions) == tolist(["codeartifact:PublishPackageVersion", "codeartifact:PutPackageMetadata"])
    error_message = "The package-scoped half must hold exactly the actions CodeArtifact requires a package resource for."
  }

  assert {
    condition     = tolist(local.publish_repository_actions) == tolist(["codeartifact:ReadFromRepository"])
    error_message = "ReadFromRepository is repository-scoped and must not be granted on a package ARN."
  }

  # Two statements for the publish grant on a published-to repository, not one: the package-scoped
  # half and the repository-scoped half carry different Resource values and cannot be merged.
  assert {
    condition     = length(local.repository_publish_statements["python"]) == 2
    error_message = "The publish grant must be split into a package-scoped and a repository-scoped statement."
  }

  # The repository-scoped half stays on "*".
  assert {
    condition = one([
      for s in local.repository_publish_statements["python"] : s.Resource if s.Sid == "PublishRepositoryAccess"
    ]) == "*"
    error_message = "The repository-scoped half of the publish grant belongs on \"*\"."
  }

  # A store repository has no publisher, so it gets no publish statement at all.
  assert {
    condition     = !contains(keys(local.repository_publish_statements), "pypi-store")
    error_message = "A store repository must never receive a publish statement."
  }
}
