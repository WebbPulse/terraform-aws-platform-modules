output "bucket_id" {
  description = "Bucket id, which for S3 is the bucket name. Use it for s3_bucket on a Lambda function and for the GitHub Actions deploy variable."
  value       = aws_s3_bucket.this.id
}

output "bucket" {
  description = "Bucket name, the same string as bucket_id, under the name a consumer usually publishes."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "Bucket ARN. Grant the deploy role s3:PutObject on the ARN with a \"/*\" suffix."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the bucket."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "placeholder_object_key" {
  description = "Key of the placeholder object, null when create_placeholder_object is false. Use it for s3_key on the Lambda function."
  value       = one(aws_s3_object.placeholder[*].key)
}

output "placeholder_object_version_id" {
  description = "Version id of the placeholder object, null when create_placeholder_object is false. Use it for s3_object_version if the function pins a version."
  value       = one(aws_s3_object.placeholder[*].version_id)
}

output "placeholder_object_etag" {
  description = "ETag of the placeholder object, null when create_placeholder_object is false."
  value       = one(aws_s3_object.placeholder[*].etag)
}
