resource "aws_codeartifact_domain" "this" {
  domain         = var.domain
  encryption_key = var.encryption_key

  tags = var.tags
}

resource "aws_codeartifact_domain_permissions_policy" "this" {
  count = local.create_domain_policy ? 1 : 0

  domain          = aws_codeartifact_domain.this.domain
  policy_document = local.domain_policy_json
}
