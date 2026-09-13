# terraform-aws-lambda-artifacts-bucket

The private, versioned S3 bucket a deploy pipeline uploads Lambda deployment packages to and the
Lambda function reads its code from, with a public access block, a lifecycle rule, optional
encryption and an optional placeholder object.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-artifacts-bucket`.

## Usage

```hcl
module "lambda_artifacts" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-artifacts-bucket"
  version = "~> 1.6"

  bucket = "example-production-lambda-artifacts"

  lifecycle_rule_id                      = "expire-noncurrent-artifacts"
  noncurrent_version_expiration_days     = 30
  abort_incomplete_multipart_upload_days = 7
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `bucket` | Bucket name; changing it replaces the bucket | required |
| `force_destroy` | Let Terraform delete a bucket that still holds objects | `false` |
| `lifecycle_rule_id` | Id of the single lifecycle rule; changing it rewrites the rule | `"expire-noncurrent-artifacts"` |
| `noncurrent_version_expiration_days` | Days a noncurrent artifact version is kept | `30` |
| `abort_incomplete_multipart_upload_days` | Days before a stalled multipart upload is aborted | `7` |
| `enable_sse` | Create the server-side encryption configuration | `false` |
| `sse_algorithm` | `AES256`, `aws:kms` or `aws:kms:dsse`, used with `enable_sse` | `"AES256"` |
| `sse_kms_master_key_id` | KMS key id or ARN for the rule; null for SSE-S3 | `null` |
| `sse_bucket_key_enabled` | S3 Bucket Keys on the rule; null leaves it unset | `null` |
| `versioning_status` | `Enabled` or `Suspended` | `"Enabled"` |
| `create_placeholder_object` | Upload a placeholder artifact so a Lambda has an object to reference | `false` |
| `placeholder_object_key` | Key of the placeholder object; changing it replaces the object | `"backend/placeholder.zip"` |
| `placeholder_object_source` | Local path of the zip, required with the placeholder | `null` |
| `placeholder_object_source_hash` | Base64 SHA256 of the zip, required with the placeholder | `null` |
| `tags` | Tags on the bucket and the placeholder object | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `bucket_id` | Bucket id, which for S3 is the bucket name |
| `bucket` | The same name, under the name a consumer usually publishes |
| `bucket_arn` | Bucket ARN; grant `s3:PutObject` on it with a `/*` suffix |
| `bucket_regional_domain_name` | Regional domain name of the bucket |
| `placeholder_object_key` | Key of the placeholder, null when not created |
| `placeholder_object_version_id` | Version id of the placeholder, null when not created |
| `placeholder_object_etag` | ETag of the placeholder, null when not created |

## Gotchas

- `create_placeholder_object = true` requires both `placeholder_object_source` and
  `placeholder_object_source_hash`; missing either fails the plan with a type conversion error
  rather than a clean validation message.
- Build the placeholder zip in the calling module, not here. `aws_s3_object` stores `source` as the
  literal path string, and an `archive_file` written inside a module resolves under
  `.terraform/modules/<name>/`, which changes that stored value.
- The noncurrent-version expiry rule only means anything while `versioning_status = "Enabled"`.
  The lifecycle configuration depends on the versioning resource so a first apply does not hit
  S3 rejecting the rule on an unversioned bucket.
- The bucket is versioned, so with `force_destroy = false` a destroy fails until the objects and
  their noncurrent versions are removed on purpose.
- `enable_sse` defaults to false. S3 encrypts every new object with AES256 regardless, so turning
  it on adds a resource to the plan without adding protection; set it deliberately, and only
  with SSE-KMS does it change behaviour.
- Bucket policies, replication, object lock, logging, CORS and additional lifecycle rules are out
  of scope; a bucket that needs them is a different bucket.
