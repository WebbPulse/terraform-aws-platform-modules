locals {
  create_key = var.create_kms_key

  key_arn = local.create_key ? aws_kms_key.this[0].arn : var.kms_key_arn

  uses_kms = local.key_arn != null

  sse_algorithm = local.uses_kms ? "aws:kms" : "AES256"

  kms_key_alias = var.kms_key_alias == null ? "alias/${var.bucket}" : (
    startswith(var.kms_key_alias, "alias/") ? var.kms_key_alias : "alias/${var.kms_key_alias}"
  )

  bucket_arn     = "arn:${data.aws_partition.current.partition}:s3:::${var.bucket}"
  objects_arn    = "${local.bucket_arn}/*"
  account_root   = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
  extra_policies = tolist(var.extra_policy_statements)

  tls_only_statement = {
    Sid       = "DenyNonTLSRequests"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:*"
    Resource  = [local.bucket_arn, local.objects_arn]
    Condition = {
      Bool = { "aws:SecureTransport" = "false" }
    }
  }

  deny_unencrypted_statement = {
    Sid       = "DenyUnencryptedObjectUploads"
    Effect    = "Deny"
    Principal = "*"
    Action    = "s3:PutObject"
    Resource  = [local.objects_arn]
    Condition = {
      StringNotEquals = { "s3:x-amz-server-side-encryption" = local.sse_algorithm }
    }
  }

  policy_statements = [
    for encoded in concat(
      var.enable_tls_only_policy ? [jsonencode(local.tls_only_statement)] : [],
      var.enable_deny_unencrypted_uploads_policy ? [jsonencode(local.deny_unencrypted_statement)] : [],
      [for s in local.extra_policies : jsonencode(s)],
    ) : jsondecode(encoded)
  ]

  create_bucket_policy = length(local.policy_statements) > 0

  bucket_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policy_statements
  })

  key_statements = local.uses_kms ? [{
    Sid      = "KMSAccess"
    Effect   = "Allow"
    Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    Resource = [local.key_arn]
  }] : []

  read_only_policy_statements = concat(
    [{
      Sid      = "ListBucket"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation"]
      Resource = [local.bucket_arn]
      }, {
      Sid      = "ReadObjects"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:GetObjectVersion"]
      Resource = [local.objects_arn]
    }],
    local.uses_kms ? [{
      Sid      = "KMSDecrypt"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:DescribeKey"]
      Resource = [local.key_arn]
    }] : [],
  )

  read_write_policy_statements = concat(
    [{
      Sid      = "ListBucket"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation"]
      Resource = [local.bucket_arn]
      }, {
      Sid    = "ReadWriteObjects"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      Resource = [local.objects_arn]
    }],
    local.key_statements,
  )

  read_only_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = local.read_only_policy_statements
  })

  read_write_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = local.read_write_policy_statements
  })

}
