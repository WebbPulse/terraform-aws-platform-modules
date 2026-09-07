# One domain per estate. Storage is deduplicated and billed once per domain, so a second domain is
# a second copy of every asset both repositories hold. The encryption key cannot be changed after
# creation; a different key means a new domain.
resource "aws_codeartifact_domain" "this" {
  domain         = var.domain
  encryption_key = var.encryption_key

  tags = var.tags
}

# GetAuthorizationToken is a domain-level action. A consumer account that holds every repository
# permission there is still cannot fetch a token without this, which is what makes the domain policy
# the single place to revoke an account's access to the whole registry.
resource "aws_codeartifact_domain_permissions_policy" "this" {
  count = local.create_domain_policy ? 1 : 0

  domain          = aws_codeartifact_domain.this.domain
  policy_document = local.domain_policy_json
}

