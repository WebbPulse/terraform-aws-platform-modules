resource "aws_kms_key" "identity_signing" {
  count = var.signing_key_count

  description = "${var.signing_key_spec} signing key ${count.index} for the ${var.name_prefix} identity function's RS256 access tokens. The private half never leaves KMS; the public half is published in the JWKS at ${var.issuer}/.well-known/jwks.json."

  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = var.signing_key_spec
  enable_key_rotation      = false
  deletion_window_in_days  = var.signing_key_deletion_window_in_days

  policy = coalesce(var.signing_key_policy_json, local.generated_signing_key_policy)

  tags = length(local.signing_key_tags) == 0 ? null : local.signing_key_tags
}

resource "aws_kms_alias" "identity_signing" {
  count = var.create_signing_key_alias ? 1 : 0

  name          = local.signing_key_alias
  target_key_id = aws_kms_key.identity_signing[var.active_signing_key].key_id
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "signing_key" {
  statement {
    sid    = "EnableIAMPoliciesInThisAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.identity_role_arn == null ? [] : [var.identity_role_arn]

    content {
      sid    = "AllowTheIdentityFunctionToSignAndPublish"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions   = local.signing_actions
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "identity_signing" {
  count = var.attach_role_policies ? 1 : 0

  name   = "identity-signing"
  role   = var.identity_role_name
  policy = local.signing_policy_json
}

resource "aws_kms_key" "identity_mfa" {
  count = var.enable_mfa_encryption_key ? 1 : 0

  description = "Symmetric envelope key for the ${var.name_prefix} identity function's TOTP seeds. Wraps a per-seed AES-256 data key through GenerateDataKey; the seed itself is encrypted locally with AES-256-GCM and never sent to KMS."

  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = var.mfa_encryption_key_rotation
  deletion_window_in_days  = var.mfa_encryption_key_deletion_window_in_days

  policy = coalesce(var.mfa_encryption_key_policy_json, local.generated_mfa_key_policy)

  tags = length(local.mfa_key_tags) == 0 ? null : local.mfa_key_tags
}

resource "aws_kms_alias" "identity_mfa" {
  count = var.enable_mfa_encryption_key && var.create_mfa_encryption_key_alias ? 1 : 0

  name          = local.mfa_key_alias
  target_key_id = aws_kms_key.identity_mfa[0].key_id
}

data "aws_iam_policy_document" "mfa_key" {
  count = var.enable_mfa_encryption_key ? 1 : 0

  statement {
    sid    = "EnableIAMPoliciesInThisAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.identity_role_arn == null ? [] : [var.identity_role_arn]

    content {
      sid    = "AllowTheIdentityFunctionToSealAndOpenTotpSeeds"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions   = local.mfa_key_actions
      resources = ["*"]

      dynamic "condition" {
        for_each = var.mfa_encryption_context_purpose == null ? [] : [var.mfa_encryption_context_purpose]

        content {
          test     = "StringEquals"
          variable = "kms:EncryptionContext:purpose"
          values   = [condition.value]
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "identity_mfa" {
  count = var.attach_role_policies && local.mfa_key_exists ? 1 : 0

  name   = "identity-mfa"
  role   = var.identity_role_name
  policy = local.mfa_policy_json
}
