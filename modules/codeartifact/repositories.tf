# Tier 0: no upstreams. The external-connection store repositories live here, along with any
# standalone repository. Nothing in this tier depends on another repository, so it is created first.
resource "aws_codeartifact_repository" "tier0" {
  for_each = local.tier0_keys

  domain      = aws_codeartifact_domain.this.domain
  repository  = each.key
  description = var.repositories[each.key].description

  dynamic "external_connections" {
    for_each = var.repositories[each.key].external_connections
    content {
      external_connection_name = external_connections.value
    }
  }

  tags = merge(var.tags, var.repositories[each.key].tags)
}

# Tier 1: upstreams only into tier 0. An upstream is named by a plain string, so Terraform cannot
# infer that the upstream repository has to exist first; depends_on says it explicitly. Creating a
# repository whose upstream does not exist yet fails outright rather than converging on a retry.
resource "aws_codeartifact_repository" "tier1" {
  for_each = local.tier1_keys

  domain      = aws_codeartifact_domain.this.domain
  repository  = each.key
  description = var.repositories[each.key].description

  dynamic "upstream" {
    for_each = var.repositories[each.key].upstreams
    content {
      repository_name = upstream.value
    }
  }

  tags = merge(var.tags, var.repositories[each.key].tags)

  depends_on = [aws_codeartifact_repository.tier0]
}

# Tier 2: upstreams into tier 0 or tier 1, which is the fan-in repository CI points at. A validation
# on the repositories variable caps chains here, so there is no tier 3.
resource "aws_codeartifact_repository" "tier2" {
  for_each = local.tier2_keys

  domain      = aws_codeartifact_domain.this.domain
  repository  = each.key
  description = var.repositories[each.key].description

  dynamic "upstream" {
    for_each = var.repositories[each.key].upstreams
    content {
      repository_name = upstream.value
    }
  }

  tags = merge(var.tags, var.repositories[each.key].tags)

  depends_on = [
    aws_codeartifact_repository.tier0,
    aws_codeartifact_repository.tier1,
  ]
}

# Read access on the repository, publish access where the caller asked for it. Both sides of a
# cross-account grant have to allow: this policy plus the domain policy above, and a matching
# identity-based policy on the principal in its own account.
resource "aws_codeartifact_repository_permissions_policy" "this" {
  for_each = local.policy_repository_keys

  domain          = aws_codeartifact_domain.this.domain
  repository      = local.repositories[each.key].repository
  policy_document = local.repository_policy_json[each.key]

  lifecycle {
    # publisher_repository_keys is checked here rather than in the variable block, because a
    # variable validation cannot look at another variable. A precondition rather than a check block:
    # granting publish on a store repository is a supply-chain hole, so it has to fail the plan
    # rather than warn on it. Left null the default is already correct, so this only fires on an
    # explicit list.
    precondition {
      condition = var.publisher_repository_keys == null || alltrue([
        for k in coalesce(var.publisher_repository_keys, []) :
        contains(keys(var.repositories), k) && length(var.repositories[k].external_connections) == 0
      ])
      error_message = "Every entry of publisher_repository_keys must name a repository in the repositories map that has no external connection. Publishing into a store repository would let a first-party package shadow the public package it proxies."
    }
  }
}

# Endpoint URLs, resolved rather than assembled by hand so a change to the CodeArtifact URL format
# does not silently produce a wrong one.
data "aws_codeartifact_repository_endpoint" "this" {
  for_each = local.endpoint_keys

  domain     = aws_codeartifact_domain.this.domain
  repository = local.repositories[each.value.repository].repository
  format     = each.value.format
}
