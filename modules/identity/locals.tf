locals {
  # Every name this module builds hangs off one prefix, joined with a hyphen. The identity
  # package's webbpulse.dynamodb.table_name builds "<prefix>-<logical>" the same way, so a table
  # this module creates and a table the application looks up are the same string by construction
  # rather than by two places agreeing.
  signing_key_name  = "${var.name_prefix}-identity-signing"
  signing_key_alias = "alias/${local.signing_key_name}"
  mfa_key_name      = "${var.name_prefix}-identity-mfa"
  mfa_key_alias     = "alias/${local.mfa_key_name}"
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

  # The MFA envelope key's tags, on the same rule as the signing key's.
  mfa_key_tags = merge(
    var.name_tag ? { Name = local.mfa_key_name } : {},
    var.tags,
  )

  # Whether a key exists at all, decided from the inputs alone.
  #
  # Separate from mfa_key_arn because a created key's ARN is not known until apply, and anything
  # that decides a resource count or a map's shape has to be known at plan time. This answers the
  # same question from the variables: there is a key when the module creates one, or when the
  # consumer supplied one of its own.
  mfa_key_exists = var.enable_mfa_encryption_key || var.mfa_encryption_key_arn != null

  # The key TOTP seeds are actually sealed under: the one this module created, or a consumer's own
  # when it supplied one and turned creation off. Null when neither exists, which is what makes
  # both the grant and IDENTITY_DATA_KEY_ARN disappear together rather than leaving a policy naming
  # a key that is not there.
  mfa_key_arn = var.enable_mfa_encryption_key ? one(aws_kms_key.identity_mfa[*].arn) : var.mfa_encryption_key_arn

  # The two calls the envelope makes, and no more.
  #
  # Deliberately not kms:Encrypt: webbpulse.identity.crypto is an envelope, so KMS mints a data key
  # through GenerateDataKey and the seed is encrypted locally under it. Nothing ever sends a
  # plaintext seed to KMS, so granting Encrypt would widen the grant for a call nothing makes.
  # Deliberately not kms:GenerateDataKeyWithoutPlaintext either, since sealing needs the plaintext
  # data key in the process to run AES-GCM with it.
  mfa_key_actions = ["kms:GenerateDataKey", "kms:Decrypt"]

  generated_mfa_key_policy = one(data.aws_iam_policy_document.mfa_key[*].json)

  # The identity role's statement on the envelope key. Scoped to the one key ARN and carrying the
  # same encryption context condition the key policy does, so neither half of the pair is wider
  # than the other.
  #
  # kms:EncryptionContext:purpose is single valued, so StringEquals is the correct operator; a set
  # operator such as ForAllValues would be wrong here per the AWS KMS condition key documentation.
  # Only purpose is pinned, because user_id differs per user and no static condition can name it.
  mfa_policy_statement = merge(
    {
      Sid      = "SealAndOpenTotpSeeds"
      Effect   = "Allow"
      Action   = local.mfa_key_actions
      Resource = [local.mfa_key_arn]
    },
    var.mfa_encryption_context_purpose == null ? {} : {
      Condition = {
        StringEquals = {
          "kms:EncryptionContext:purpose" = var.mfa_encryption_context_purpose
        }
      }
    },
  )

  mfa_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.mfa_policy_statement]
  })

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
  # IDENTITY_DATA_KEY_ARN is the M4 addition, and it is merged conditionally rather than set to an
  # empty string when there is no key. IdentitySettings.data_key_arn defaults to "", and
  # EnvelopeCipher refuses to construct on an empty key id with a message naming this setting, so
  # an absent variable and an empty one behave identically to the package. Omitting it keeps the
  # function's rendered environment honest about which keys exist.
  #
  # The name is the field name under the IDENTITY_ prefix: IdentitySettings.data_key_arn, not
  # "envelope" or "mfa" anything. It is the setting that has existed since M1 as a placeholder and
  # that M4 is the first release to read.
  mfa_environment = local.mfa_key_exists ? {
    IDENTITY_DATA_KEY_ARN = local.mfa_key_arn
  } : {}

  identity_environment = merge(
    {
      IDENTITY_ISSUER           = var.issuer
      IDENTITY_AUDIENCE         = var.audience
      IDENTITY_SIGNING_KEY_ARNS = jsonencode(local.signing_key_arns)
      IDENTITY_COOKIE_DOMAIN    = var.registrable_domain
      IDENTITY_RP_ID            = var.registrable_domain
    },
    local.mfa_environment,
  )
}
