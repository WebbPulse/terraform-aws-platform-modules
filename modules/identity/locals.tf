locals {
  signing_key_name  = "${var.name_prefix}-identity-signing"
  signing_key_alias = "alias/${local.signing_key_name}"
  mfa_key_name      = "${var.name_prefix}-identity-mfa"
  mfa_key_alias     = "alias/${local.mfa_key_name}"
  authorizer_name   = coalesce(var.authorizer_name, "${var.name_prefix}-identity-jwt")

  tags = length(var.tags) > 0 ? var.tags : null

  signing_key_tags = merge(
    var.name_tag ? { Name = local.signing_key_name } : {},
    var.tags,
  )

  mfa_key_tags = merge(
    var.name_tag ? { Name = local.mfa_key_name } : {},
    var.tags,
  )

  mfa_key_exists = var.enable_mfa_encryption_key || var.mfa_encryption_key_arn != null

  mfa_key_arn = var.enable_mfa_encryption_key ? one(aws_kms_key.identity_mfa[*].arn) : var.mfa_encryption_key_arn

  mfa_key_actions = ["kms:GenerateDataKey", "kms:Decrypt"]

  generated_mfa_key_policy = one(data.aws_iam_policy_document.mfa_key[*].json)

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

  signing_key_indexes = range(var.signing_key_count)

  signing_key_order = concat(
    [var.active_signing_key],
    [for i in local.signing_key_indexes : i if i != var.active_signing_key],
  )

  signing_key_arns = [for i in local.signing_key_order : aws_kms_key.identity_signing[i].arn]

  active_signing_key_arn = aws_kms_key.identity_signing[var.active_signing_key].arn

  signing_actions = ["kms:Sign", "kms:GetPublicKey"]

  generated_signing_key_policy = data.aws_iam_policy_document.signing_key.json

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

  additional_grant_resources = {
    for name, grant in var.additional_table_grants : name => flatten([
      for table in sort(grant.tables) : [
        aws_dynamodb_table.this[table].arn,
        "${aws_dynamodb_table.this[table].arn}/index/*",
      ]
    ])
  }

  additional_grant_policy_json = {
    for name, grant in var.additional_table_grants : name => jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "IdentityTableAccess"
          Effect   = "Allow"
          Action   = coalesce(grant.actions, var.table_policy_actions)
          Resource = local.additional_grant_resources[name]
        },
      ]
    })
  }

  mfa_environment = local.mfa_key_exists ? {
    IDENTITY_DATA_KEY_ARN = local.mfa_key_arn
  } : {}

  refresh_user_index_name = try(
    one([
      for index in var.tables["refresh-tokens"].global_secondary_indexes :
      index.name if index.hash_key == "user_id"
    ]),
    null,
  )

  refresh_user_index_environment = local.refresh_user_index_name == null ? {} : {
    IDENTITY_REFRESH_USER_INDEX = local.refresh_user_index_name
  }

  users_stream_environment = var.users_stream_enabled ? {
    AWS_LWA_PASS_THROUGH_PATH    = var.users_stream_events_path
    IDENTITY_EVENTS_PATH         = var.users_stream_events_path
    IDENTITY_USERS_KEY_ATTRIBUTE = var.users_key_attribute
  } : {}

  users_stream_policy_actions = [
    "dynamodb:DescribeStream",
    "dynamodb:GetRecords",
    "dynamodb:GetShardIterator",
    "dynamodb:ListStreams",
  ]

  users_stream_policy_json = var.users_stream_enabled ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadTheUsersTableStream"
        Effect   = "Allow"
        Action   = local.users_stream_policy_actions
        Resource = [var.users_table_stream_arn]
      },
    ]
  }) : null

  identity_environment = merge(
    {
      IDENTITY_ISSUER           = var.issuer
      IDENTITY_AUDIENCE         = var.audience
      IDENTITY_SIGNING_KEY_ARNS = jsonencode(local.signing_key_arns)
      IDENTITY_COOKIE_DOMAIN    = var.registrable_domain
      IDENTITY_RP_ID            = var.registrable_domain
    },
    local.refresh_user_index_environment,
    local.mfa_environment,
    local.users_stream_environment,
  )
}
