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

resource "aws_codeartifact_repository_permissions_policy" "this" {
  for_each = local.policy_repository_keys

  domain          = aws_codeartifact_domain.this.domain
  repository      = local.repositories[each.key].repository
  policy_document = local.repository_policy_json[each.key]

  lifecycle {
    precondition {
      condition = var.publisher_repository_keys == null || alltrue([
        for k in coalesce(var.publisher_repository_keys, []) :
        contains(keys(var.repositories), k) && length(var.repositories[k].external_connections) == 0
      ])
      error_message = "Every entry of publisher_repository_keys must name a repository in the repositories map that has no external connection. Publishing into a store repository would let a first-party package shadow the public package it proxies."
    }
  }
}

data "aws_codeartifact_repository_endpoint" "this" {
  for_each = local.endpoint_keys

  domain     = aws_codeartifact_domain.this.domain
  repository = local.repositories[each.value.repository].repository
  format     = each.value.format
}
