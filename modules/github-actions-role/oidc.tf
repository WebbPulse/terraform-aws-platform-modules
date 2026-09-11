resource "aws_iam_openid_connect_provider" "this" {
  count = var.create_oidc_provider ? 1 : 0

  url             = local.oidc_provider_url
  client_id_list  = [var.audience]
  thumbprint_list = var.oidc_thumbprints

  tags = local.tags
}
