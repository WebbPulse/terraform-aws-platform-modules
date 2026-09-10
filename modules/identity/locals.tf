locals {
  # Every name this module builds hangs off one prefix, joined with a hyphen. The identity
  # package's webbpulse.dynamodb.table_name builds "<prefix>-<logical>" the same way, so a table
  # this module creates and a table the application looks up are the same string by construction
  # rather than by two places agreeing.
  signing_key_name  = "${var.name_prefix}-identity-signing"
  signing_key_alias = "alias/${local.signing_key_name}"
  authorizer_name   = coalesce(var.authorizer_name, "${var.name_prefix}-identity-jwt")

  # An unset tags argument and an empty map plan identically on provider 5.x, but passing null
  # keeps the configuration byte-for-byte what an adopting consumer had before the move.
  tags = length(var.tags) > 0 ? var.tags : null

  # The signing key's own tags. name_tag adds Name = <name_prefix>-identity-signing, matching what
  # a hand-written key in an estate that carries a Name tag already has, so adopting one is a move
  # with no tag diff. var.tags wins, so a consumer can still override Name outright.
  signing_key_tags = merge(
    var.name_tag ? { Name = local.signing_key_name } : {},
    var.tags,
  )

  table_names = {
    for key, table in var.tables : key => "${var.name_prefix}-${key}"
  }

  table_tags = {
    for key, table in var.tables : key => merge(
      var.name_tag ? { Name = local.table_names[key] } : {},
      var.tags,
      table.tags,
    )
  }

  # The signing keys, in the order the package expects.
  #
  # webbpulse.identity.IdentitySettings reads IDENTITY_SIGNING_KEY_ARNS as an ordered list and
  # takes signing_key_arns[0] as the active signer, publishing every entry in the JWKS. So the
  # order of this list is the whole of the rotation design and is not cosmetic: sorting it, or
  # letting a map's key order decide it, would silently change which key signs.
  #
  # The active key comes first and the rest follow in index order. Nothing is sorted.
  signing_key_indexes = range(var.signing_key_count)

  signing_key_order = concat(
    [var.active_signing_key],
    [for i in local.signing_key_indexes : i if i != var.active_signing_key],
  )

  signing_key_arns = [for i in local.signing_key_order : aws_kms_key.identity_signing[i].arn]

  active_signing_key_arn = aws_kms_key.identity_signing[var.active_signing_key].arn

  # The two grants the identity function needs on the signing keys, and no more.
  #
  # kms:Sign and kms:GetPublicKey, and deliberately no kms:Verify: verification happens at the API
  # Gateway authorizer against the public JWKS and locally against a public key, never through KMS,
  # so granting Verify would widen the grant for a call nothing makes. kms:DescribeKey is not
  # granted either, because the token service reads the key spec off the GetPublicKey response,
  # which already carries it.
  signing_actions = ["kms:Sign", "kms:GetPublicKey"]

  generated_signing_key_policy = data.aws_iam_policy_document.signing_key.json

  # Every key, not only the active one: during a rotation the JWKS publishes both, and serving a
  # JWK means calling GetPublicKey on that key.
  signing_key_arns_sorted = sort([for k in aws_kms_key.identity_signing : k.arn])

  signing_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SignAccessTokensAndPublishTheJwks"
        Effect   = "Allow"
        Action   = local.signing_actions
        Resource = local.signing_key_arns_sorted
      },
    ]
  })

  # The table grant. Every table this module creates plus every index on them, which is what the
  # refresh token family query needs.
  #
  # Sorted by table key so the rendered document is stable: a policy whose statement order moves
  # with a map's iteration order shows a diff on a plan that changed nothing.
  table_arns_list = [for key in sort(keys(aws_dynamodb_table.this)) : aws_dynamodb_table.this[key].arn]

  table_policy_resources = concat(
    local.table_arns_list,
    [for arn in local.table_arns_list : "${arn}/index/*"],
  )

  table_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "IdentityTableAccess"
        Effect   = "Allow"
        Action   = var.table_policy_actions
        Resource = local.table_policy_resources
      },
    ]
  })

  # The IDENTITY_ environment block, ready to merge into the identity function's environment.
  #
  # Every name here is a field of webbpulse.identity.IdentitySettings, whose env_prefix is
  # IDENTITY_, so the composition root builds the settings object straight from the environment
  # with no per-field plumbing.
  #
  # IDENTITY_SIGNING_KEY_ARNS is a JSON array rather than a bare comma separated string, because
  # IdentitySettings deliberately refuses CSV for list fields: these are ARNs, and a stray comma
  # should be an error rather than a silently split entry.
  #
  # Naming the key ARNs here does not create a dependency cycle even though the key policy names
  # the identity role. The cycle would exist if the key were built from something the Lambda
  # module produces and that module were built from the key; Terraform's graph is per resource
  # rather than per module, so the order is role, then key, then function.
  identity_environment = {
    IDENTITY_ISSUER           = var.issuer
    IDENTITY_AUDIENCE         = var.audience
    IDENTITY_SIGNING_KEY_ARNS = jsonencode(local.signing_key_arns)
    IDENTITY_COOKIE_DOMAIN    = var.registrable_domain
    IDENTITY_RP_ID            = var.registrable_domain
  }
}
