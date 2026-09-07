# A deploy role for a single-page app on S3 + CloudFront with a Lambda API. Every workflow in the
# repository may assume it; narrow `subjects` to an environment or branch claim to tighten that.
# The role ARN goes on the GitHub environment as AWS_DEPLOY_ROLE_ARN and into
# aws-actions/configure-aws-credentials as role-to-assume.

module "github_actions_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 1.2"

  role_name = "example-production-github-actions-deploy"
  subjects  = ["repo:WebbPulse/example:*"]

  policy_statements = [
    {
      sid       = "LambdaArtifacts"
      actions   = ["s3:PutObject", "s3:GetObject"]
      resources = ["${aws_s3_bucket.lambda_artifacts.arn}/*"]
    },
    {
      sid = "LambdaCode"
      actions = [
        "lambda:UpdateFunctionCode",
        "lambda:PublishVersion",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
      ]
      resources = [aws_lambda_function.api.arn]
    },
    {
      sid = "FrontendSync"
      actions = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.frontend.arn,
        "${aws_s3_bucket.frontend.arn}/*",
      ]
    },
    {
      sid       = "FrontendInvalidate"
      actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
      resources = [aws_cloudfront_distribution.frontend.arn]
    },
  ]
}

# A second stack in the same account cannot create the provider again; it points at this one.
#
# module "other_repo_role" {
#   source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
#   version = "~> 1.2"
#
#   role_name            = "other-production-github-actions-deploy"
#   subjects             = ["repo:WebbPulse/other:environment:production"]
#   create_oidc_provider = false
#   oidc_provider_arn    = module.github_actions_role.oidc_provider_arn
#   policy_statements    = [...]
# }

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC deployments"
  value       = module.github_actions_role.role_arn
}

# The application resources the role deploys to. Trimmed to what the example needs.

resource "aws_s3_bucket" "frontend" {
  bucket = "example-production-frontend"
}

resource "aws_s3_bucket" "lambda_artifacts" {
  bucket = "example-production-lambda-artifacts"
}

resource "aws_lambda_function" "api" {
  function_name = "example-production-api"
  role          = aws_iam_role.lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  s3_bucket     = aws_s3_bucket.lambda_artifacts.id
  s3_key        = "api.zip"
}

resource "aws_iam_role" "lambda" {
  name = "example-production-api"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "s3-frontend"
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
