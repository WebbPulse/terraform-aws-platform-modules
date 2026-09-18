output "bucket" {
  description = "Bucket name, the string a Terraform S3 backend's bucket argument and every consumer takes."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_id" {
  description = "Bucket id, which for S3 is the bucket name. The same string as bucket, under the other convention."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "Bucket ARN with no suffix. A grant on the objects appends \"/*\" to it."
  value       = aws_s3_bucket.this.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the bucket, which is the endpoint a client should use rather than the global one."
  value       = aws_s3_bucket.this.bucket_regional_domain_name
}

output "bucket_domain_name" {
  description = "Global domain name of the bucket."
  value       = aws_s3_bucket.this.bucket_domain_name
}

output "region" {
  description = "Region the bucket lives in, for a backend block or a client that has to name it."
  value       = aws_s3_bucket.this.region
}

output "kms_key_arn" {
  description = "ARN of the key encrypting the bucket: the created key, or the kms_key_arn input when one was given, or null on an SSE-S3 bucket. This is the ARN a consumer's own KMS grant names."
  value       = local.key_arn
}

output "kms_key_id" {
  description = "Id of the created KMS key, null when the module did not create one."
  value       = one(aws_kms_key.this[*].key_id)
}

output "kms_key_alias" {
  description = "Alias of the created KMS key, null when no alias was created."
  value       = one(aws_kms_alias.this[*].name)
}

output "read_only_policy_json" {
  description = "IAM policy JSON granting list and read on this bucket and decrypt on its key, scoped to this bucket alone. Attach it to a role that consumes what the bucket holds; it grants nothing else."
  value       = local.read_only_policy_json
}

output "read_write_policy_json" {
  description = "IAM policy JSON granting list, read, write, delete and the multipart actions on this bucket plus encrypt and decrypt on its key, scoped to this bucket alone. This is the shape a Terraform S3 backend needs, and it deliberately includes no s3:*."
  value       = local.read_write_policy_json
}

output "read_only_policy_statements" {
  description = "The read-only policy as a statement list rather than JSON, to merge into a role that already carries other statements. Feed it to the github-actions-role module's policy_statements input."
  value       = local.read_only_policy_statements
}

output "read_write_policy_statements" {
  description = "The read-write policy as a statement list rather than JSON, to merge into a role that already carries other statements."
  value       = local.read_write_policy_statements
}

output "bucket_policy_json" {
  description = "The bucket policy this module wrote, null when no statement was asked for. Read it to see exactly what the TLS-only and encryption statements deny."
  value       = local.create_bucket_policy ? local.bucket_policy_json : null
}
