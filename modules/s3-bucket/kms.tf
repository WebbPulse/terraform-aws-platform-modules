data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "key" {
  count = local.create_key ? 1 : 0

  statement {
    sid    = "EnableIAMPoliciesInThisAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.kms_key_extra_principal_arns) > 0 ? [1] : []

    content {
      sid    = "AllowNamedPrincipalsToUseTheKey"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = sort(distinct(var.kms_key_extra_principal_arns))
      }

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]

      resources = ["*"]
    }
  }
}

resource "aws_kms_key" "this" {
  count = local.create_key ? 1 : 0

  description                        = coalesce(var.kms_key_description, "Encrypts every object in the ${var.bucket} bucket.")
  key_usage                          = "ENCRYPT_DECRYPT"
  customer_master_key_spec           = "SYMMETRIC_DEFAULT"
  enable_key_rotation                = var.kms_key_rotation_enabled
  deletion_window_in_days            = var.kms_key_deletion_window_in_days
  bypass_policy_lockout_safety_check = false

  policy = coalesce(var.kms_key_policy_json, data.aws_iam_policy_document.key[0].json)

  tags = var.tags
}

resource "aws_kms_alias" "this" {
  count = local.create_key && var.create_kms_key_alias ? 1 : 0

  name          = local.kms_key_alias
  target_key_id = aws_kms_key.this[0].key_id
}
