# The bucket GitHub Actions uploads Lambda deployment packages to, and the Lambda function reads
# its code from. Versioned so a bad deploy can be rolled back to the previous object version, and
# swept so old versions and stalled multipart uploads do not accumulate.
resource "aws_s3_bucket" "this" {
  bucket        = var.bucket
  force_destroy = var.force_destroy

  tags = var.tags
}

# Deployment packages are never public. Nothing here is served to a browser.
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

# One rule, unfiltered: drop noncurrent versions after their retention and abort multipart uploads
# that were never completed. Current versions are kept, the Lambda reads one of them.
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

  # A noncurrent-version rule needs versioning on the bucket, which only matters on the first
  # apply. Toggling this changes no attribute of the configuration itself.
  depends_on = [aws_s3_bucket_versioning.this]
}

# A stand-in deployment package so the Lambda has an object to point at before the first real
# deploy. The zip is built by the caller; this only puts it in place.
resource "aws_s3_object" "placeholder" {
  count = local.placeholder_count

  bucket      = aws_s3_bucket.this.id
  key         = var.placeholder_object_key
  source      = var.placeholder_object_source
  source_hash = var.placeholder_object_source_hash

  tags = var.tags
}
