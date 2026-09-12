variables {
  name_prefix = "example-staging"

  repositories = {
    content  = {}
    resume   = {}
    identity = {}
    public   = {}
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "every_output_map_is_keyed_by_the_short_domain_key_the_caller_passed" {
  command = plan

  override_resource {
    target          = aws_ecr_repository.this
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/placeholder"
      repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-staging/placeholder"
      registry_id    = "123456789012"
    }
  }

  assert {
    condition     = sort(keys(output.repository_names)) == tolist(["content", "identity", "public", "resume"])
    error_message = "The output maps must be keyed by the short domain key rather than the full repository name, because that key is what a consumer already has in hand when it wants a repository."
  }

  assert {
    condition     = sort(keys(output.repository_urls)) == sort(keys(output.repository_names))
    error_message = "Every output map must cover the same repositories. A key present in one map and missing from another turns a consumer's lookup into a plan time error for reasons that are hard to trace."
  }

  assert {
    condition     = sort(keys(output.repository_arns)) == sort(keys(output.repository_names))
    error_message = "repository_arns must cover exactly the same keys as the other maps."
  }

  assert {
    condition     = sort(keys(output.repositories)) == sort(keys(output.repository_names))
    error_message = "The combined repositories output must cover the same keys, since it exists so a consumer can reach any repository's name, ARN, URL and registry id without a second lookup."
  }
}

run "repository_names_carries_the_full_prefixed_name_an_ecr_api_call_takes" {
  command = plan

  override_resource {
    target          = aws_ecr_repository.this
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/placeholder"
      repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-staging/placeholder"
      registry_id    = "123456789012"
    }
  }

  assert {
    condition     = output.repository_names["content"] == "example-staging/content"
    error_message = "repository_names must give the full <name_prefix>/<key> name. The name, not the URL, is what an ECR API call takes as repositoryName, so a consumer building a call from the short key alone would address a repository that does not exist."
  }

  assert {
    condition = alltrue([
      for key, name in output.repository_names : name == "example-staging/${key}"
    ])
    error_message = "Every entry must follow the same prefixed naming rule, so a consumer can rely on the map rather than rebuilding the name by hand."
  }

  assert {
    condition     = output.repositories["content"].name == output.repository_names["content"]
    error_message = "The name inside the combined repositories output must agree with the dedicated repository_names map; two outputs that disagree about the same repository is a bug waiting to be found in production."
  }
}

run "repository_arns_list_is_sorted_by_key_so_an_iam_policy_plans_stably" {
  command = plan

  override_resource {
    target          = aws_ecr_repository.this
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/placeholder"
      repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-staging/placeholder"
      registry_id    = "123456789012"
    }
  }

  assert {
    condition     = length(output.repository_arns_list) == 4
    error_message = "repository_arns_list must hold one ARN per repository. Both consumer estates drop this list straight into the resource list of their EcrPushDomainImages statement, so a short list is a domain CI cannot push."
  }

  assert {
    condition     = length(output.repository_arns_list) == length(output.repository_arns)
    error_message = "The list form and the map form must describe the same set of repositories, since the list is only the map flattened for an IAM policy."
  }

  assert {
    condition     = output.repository_arns_list == [for key in sort(keys(var.repositories)) : output.repository_arns[key]]
    error_message = "The list must be ordered by sorted key rather than by map iteration order. An unstable order would reorder the resource list of the deploy role's inline policy on every plan, producing a permanent diff that changes nothing."
  }
}

run "the_urls_and_arns_come_from_the_resource_rather_than_being_rebuilt_by_hand" {
  command = plan

  override_resource {
    target          = aws_ecr_repository.this
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/placeholder"
      repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-staging/placeholder"
      registry_id    = "123456789012"
    }
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      output.repository_urls[key] == aws_ecr_repository.this[key].repository_url
    ])
    error_message = "repository_urls must be read off the resource, not assembled from an account id and a region. It is the map CI pushes to and a Lambda image_uri is built from as <url>:sha-<commit>, so nothing should be rebuilding a registry hostname by hand."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      output.repository_arns[key] == aws_ecr_repository.this[key].arn
    ])
    error_message = "repository_arns must be read off the resource so the ARN is always the real one, including its partition."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      output.repositories[key].url == output.repository_urls[key]
    ])
    error_message = "The URL in the combined output must agree with the dedicated repository_urls map."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      output.repositories[key].arn == output.repository_arns[key]
    ])
    error_message = "The ARN in the combined output must agree with the dedicated repository_arns map."
  }
}

run "the_registry_id_collapses_to_the_one_account_every_repository_shares" {
  command = plan

  override_resource {
    target          = aws_ecr_repository.this
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/placeholder"
      repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-staging/placeholder"
      registry_id    = "123456789012"
    }
  }

  assert {
    condition     = output.registry_id == "123456789012"
    error_message = "Every repository in one module block lives in the same registry, which is the account, so registry_id must collapse to a single value rather than making each consumer pick one out of a map."
  }

  assert {
    condition = alltrue([
      for key in keys(var.repositories) :
      output.repositories[key].registry_id == output.registry_id
    ])
    error_message = "The registry id inside the combined output must agree with the collapsed single value for every repository."
  }
}

run "an_empty_repositories_map_yields_empty_outputs_and_a_null_registry" {
  command = plan

  variables {
    repositories = {}
  }

  assert {
    condition     = output.registry_id == null
    error_message = "With no repositories there is no registry to name, so registry_id must be null. Collapsing an empty list must not fail the plan, because a consumer may legitimately wire the module in before it has a domain list."
  }

  assert {
    condition     = length(output.repository_arns_list) == 0
    error_message = "An empty repositories map must produce an empty ARN list, which an IAM policy consumer can then decide to skip rather than being handed a broken value."
  }

  assert {
    condition     = length(output.repository_urls) == 0
    error_message = "Every output map must be empty rather than null when there are no repositories, so a consumer can iterate it unconditionally."
  }

  assert {
    condition     = length(output.repositories) == 0
    error_message = "The combined output must also be an empty map rather than null."
  }

  assert {
    condition     = length(output.repository_names) == 0
    error_message = "repository_names must be an empty map as well, keeping every output consistent in the empty case."
  }
}

run "outputs_follow_an_unprefixed_repository_name_too" {
  command = plan

  variables {
    name_prefix = ""

    repositories = {
      "webbpulse/python-lambda-base" = {}
    }
  }

  override_resource {
    target          = aws_ecr_repository.this
    override_during = plan
    values = {
      arn            = "arn:aws:ecr:us-west-2:123456789012:repository/example-staging/placeholder"
      repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-staging/placeholder"
      registry_id    = "123456789012"
    }
  }

  assert {
    condition     = output.repository_names["webbpulse/python-lambda-base"] == "webbpulse/python-lambda-base"
    error_message = "With no prefix the output name must be the key verbatim. This is the shape of the shared base image repository both consumer estates pull from, so the unprefixed case has to work as well as the prefixed one."
  }

  assert {
    condition     = length(output.repository_arns_list) == 1
    error_message = "A single repository must still produce a one element ARN list rather than a bare value, so a consumer's policy resource list does not change shape with the repository count."
  }
}
