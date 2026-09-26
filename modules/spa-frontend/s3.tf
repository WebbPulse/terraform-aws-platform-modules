resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = local.origin_access_control_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  cloudfront_read_statement = {
    Sid    = var.bucket_policy_sid
    Effect = "Allow"
    Principal = {
      Service = "cloudfront.amazonaws.com"
    }
    Action   = "s3:GetObject"
    Resource = "${aws_s3_bucket.this.arn}/*"
    Condition = {
      StringEquals = {
        "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
      }
    }
  }

  cloudfront_list_statement = {
    Sid    = "AllowCloudFrontListForMissingKeys"
    Effect = "Allow"
    Principal = {
      Service = "cloudfront.amazonaws.com"
    }
    Action   = "s3:ListBucket"
    Resource = aws_s3_bucket.this.arn
    Condition = {
      StringEquals = {
        "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
      }
    }
  }

  bucket_policy_statements = local.gate_enabled ? [local.cloudfront_read_statement, local.cloudfront_list_statement] : [local.cloudfront_read_statement]
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.bucket_policy_statements
  })
}
