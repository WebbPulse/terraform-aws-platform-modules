resource "aws_s3_bucket" "this" {
  bucket        = var.bucket
  force_destroy = var.force_destroy

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_status
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  count = var.enable_sse ? 1 : 0

  bucket = aws_s3_bucket.this.id

  rule {
    bucket_key_enabled = var.sse_bucket_key_enabled

    apply_server_side_encryption_by_default {
      sse_algorithm     = var.sse_algorithm
      kms_master_key_id = var.sse_kms_master_key_id
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = var.lifecycle_rule_id
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_object" "placeholder" {
  count = local.placeholder_count

  bucket      = aws_s3_bucket.this.id
  key         = var.placeholder_object_key
  source      = var.placeholder_object_source
  source_hash = var.placeholder_object_source_hash

  tags = var.tags
}
