# terraform-aws-lambda-artifacts-bucket

The private, versioned S3 bucket a deploy pipeline uploads Lambda deployment packages to and the
Lambda function reads its code from: the bucket, its public access block, versioning, a lifecycle
rule that expires noncurrent versions and aborts stalled multipart uploads, an optional SSE-S3
encryption rule, and an optional placeholder object so the function has something to point at
before the first real deploy.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-artifacts-bucket`.
The Lambda function, its role and the pipeline's IAM permissions stay with the consumer; the
module hands back the bucket name and ARN they need.

## What it creates

```
aws_s3_bucket.this                                          the bucket, optional force_destroy
aws_s3_bucket_public_access_block.this                      all four blocks on, always
aws_s3_bucket_versioning.this                               Enabled by default
aws_s3_bucket_lifecycle_configuration.this                  one unfiltered rule, after versioning
aws_s3_bucket_server_side_encryption_configuration.this[0]  only with enable_sse
aws_s3_object.placeholder[0]                                only with create_placeholder_object
```

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

`examples/lambda-artifacts-bucket-basic` at the repository root is the fuller version, with the
encryption rule, the placeholder object and the Lambda function that reads from it.

## Why the lifecycle rule looks the way it does

The bucket is versioned so a bad deploy can be rolled back to the previous object version, which
means every deploy leaves the old package behind as a noncurrent version. The single rule sweeps
those after `noncurrent_version_expiration_days` and aborts multipart uploads that a failed CI job
left half finished after `abort_incomplete_multipart_upload_days`. Current versions are never
touched, the function is reading one of them.

`filter {}` is deliberate. An empty filter is how the AWS provider writes "this rule applies to
every object", and it is what both consumers have in state; omitting the block entirely is a
different configuration, and the provider warns about a rule with neither `filter` nor `prefix`.

The lifecycle configuration is ordered after the versioning resource with `depends_on`. That only
matters on a first apply, where S3 can reject a noncurrent-version rule on a bucket that is not
yet versioned. It sets no attribute, so it is invisible on a bucket that already exists, which is
why one consumer having written it by hand and the other not is not a difference the module has to
carry as a variable.

## The placeholder object

A Lambda function needs `s3_key` to resolve to a real object at create time, so an application
that deploys code through CI has a chicken and egg problem on its first apply. The placeholder is
a tiny zip whose handler answers 503, uploaded once so the function can be created; CI overwrites
it on the first real deploy, and the function carries
`lifecycle { ignore_changes = [s3_key, s3_object_version, source_code_hash] }` so Terraform stops
tracking which package is live after that.

The zip itself is built by the consumer, not the module, and passed in as
`placeholder_object_source` and `placeholder_object_source_hash`. That split is not arbitrary:
`aws_s3_object` stores `source` in state as the literal path string it was given. A
`data "archive_file"` whose `output_path` is `"${path.module}/.terraform/lambda-placeholder.zip"`
resolves to `./.terraform/lambda-placeholder.zip` in a root module and to
`.terraform/modules/<name>/...` inside a module, so moving the archive into the module would
change that stored string and cost the adopting application a diff. Keeping the archive with the
caller keeps the path, and the state, identical.

An application that uploads its placeholder through CI instead, or that ships the placeholder as a
local `filename` on the function rather than through S3, leaves `create_placeholder_object` false
and gets a bucket with nothing in it.

## Encryption

`enable_sse` is false by default, which is the safe adoption stance rather than the safe security
stance. S3 has encrypted every new object with AES256 since January 2023 whether or not a bucket
carries an `aws_s3_bucket_server_side_encryption_configuration`, so the resource makes the setting
explicit rather than adding protection. Turning it on for a bucket that has never had one adds a
resource to the plan, so an adopting application matches whatever it has today and can flip it
later as its own one-line change.

With `enable_sse = true`, the defaults reproduce a plain SSE-S3 rule: `sse_algorithm = "AES256"`,
`sse_kms_master_key_id = null` and `sse_bucket_key_enabled = null`. For SSE-KMS, set
`sse_algorithm = "aws:kms"` with a key id, and consider `sse_bucket_key_enabled = true` to cut KMS
request cost.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `bucket` | Bucket name; changing it replaces the bucket | required |
| `force_destroy` | Let Terraform delete a bucket that still holds objects | `false` |
| `lifecycle_rule_id` | Id of the single lifecycle rule | `"expire-noncurrent-artifacts"` |
| `noncurrent_version_expiration_days` | Days a noncurrent version is kept | `30` |
| `abort_incomplete_multipart_upload_days` | Days before a stalled multipart upload is aborted | `7` |
| `enable_sse` | Create the server-side encryption configuration | `false` |
| `sse_algorithm` | `AES256`, `aws:kms` or `aws:kms:dsse`, with `enable_sse` | `"AES256"` |
| `sse_kms_master_key_id` | KMS key for the rule; null for SSE-S3 | `null` |
| `sse_bucket_key_enabled` | S3 Bucket Keys on the rule; null leaves it unset | `null` |
| `versioning_status` | `Enabled` or `Suspended` | `"Enabled"` |
| `create_placeholder_object` | Upload the placeholder package | `false` |
| `placeholder_object_key` | Key of the placeholder object | `"backend/placeholder.zip"` |
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

## Adoption

Both applications move their existing resources into the module with `moved` blocks. The inputs
below reproduce every attribute each application has in state today. The speculative plans on the
staging workspaces read "0 to add, 0 to change, 0 to destroy", with only the move notices.

Three things are worth knowing about before reading the blocks:

- Neither application tags these resources inline; both get `Project`, `Environment` and
  `ManagedBy` from provider `default_tags`. So `tags` stays at its `{}` default in both, which is
  what `tags` holds in state, and `tags_all` keeps coming from the provider.
- The lifecycle rule id differs between the two applications and is therefore an input rather than
  a constant. Changing it rewrites the rule in place, so neither application can adopt the other's
  name for free.
- WebbPulse-Portfolio keeps its `data "archive_file" "lambda_placeholder"` where it is and passes
  the two placeholder inputs. Moving the archive into the module would change the `source` path
  stored on the object; see "The placeholder object" above.

### CarModPicker

In `terraform/s3.tf`, the four `lambda_artifacts` resources are replaced by the module block. The
`user_images` and `crawl_data` buckets in the same file are untouched.

```hcl
module "lambda_artifacts" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-artifacts-bucket"
  version = "~> 1.6"

  bucket = "${local.prefix}-lambda-artifacts"

  lifecycle_rule_id                      = "expire-noncurrent-artifacts"
  noncurrent_version_expiration_days     = 30
  abort_incomplete_multipart_upload_days = 7
  # enable_sse and create_placeholder_object stay false: CarModPicker has neither today. Its
  # Lambda ships the placeholder as a local filename, not through S3.
}

moved {
  from = aws_s3_bucket.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_public_access_block.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_versioning.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket_versioning.this
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket_lifecycle_configuration.this
}
```

Then two references follow the bucket out of the root module: in `iam_github_actions.tf`,
`resources = ["${module.lambda_artifacts.bucket_arn}/*"]`, and in `outputs.tf`,
`lambda_artifacts_bucket = module.lambda_artifacts.bucket_id`.

Note that `lifecycle_rule_id` is passed explicitly even though `"expire-noncurrent-artifacts"` is
also the module default. The rule id is the one input where a silent default change would rewrite
a rule, so it reads better named at the call site.

### WebbPulse-Portfolio

In `terraform/lambda.tf`, the five `lambda_artifacts` resources and `aws_s3_object.lambda_placeholder`
are replaced by the module block. `data "archive_file" "lambda_placeholder"` stays exactly where it
is, and so does everything from `aws_cloudwatch_log_group.lambda_api` onwards.

```hcl
module "lambda_artifacts" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-artifacts-bucket"
  version = "~> 1.6"

  bucket = "${local.prefix}-lambda-artifacts"

  lifecycle_rule_id                      = "expire-noncurrent"
  noncurrent_version_expiration_days     = 30
  abort_incomplete_multipart_upload_days = 7

  enable_sse = true

  create_placeholder_object      = true
  placeholder_object_key         = "backend/placeholder.zip"
  placeholder_object_source      = data.archive_file.lambda_placeholder.output_path
  placeholder_object_source_hash = data.archive_file.lambda_placeholder.output_base64sha256
}

moved {
  from = aws_s3_bucket.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_public_access_block.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_versioning.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket_versioning.this
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket_server_side_encryption_configuration.this[0]
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.lambda_artifacts
  to   = module.lambda_artifacts.aws_s3_bucket_lifecycle_configuration.this
}

moved {
  from = aws_s3_object.lambda_placeholder
  to   = module.lambda_artifacts.aws_s3_object.placeholder[0]
}
```

The two optional resources are `count`-gated inside the module, so their `moved` targets carry the
`[0]` index while the four unconditional ones do not.

Then three references follow the bucket out: in `lambda.tf`,
`s3_bucket = module.lambda_artifacts.bucket_id` and
`s3_key = module.lambda_artifacts.placeholder_object_key` on `aws_lambda_function.api`
(`source_code_hash` keeps reading the archive directly); in `iam_github_actions.tf`,
`resources = [module.lambda_artifacts.bucket_arn, "${module.lambda_artifacts.bucket_arn}/*"]`; and
in `outputs.tf`, `lambda_artifact_bucket = module.lambda_artifacts.bucket_id`.

Once both applications are on the module, the `moved` blocks can be deleted after one apply each.

## Not covered

Bucket policies, replication, object lock, logging, CORS, intelligent tiering, transitions to
colder storage classes, and more than one lifecycle rule. An artifacts bucket wants none of them;
a bucket that does is a different bucket and belongs in its own module. CarModPicker's
`user_images` and `crawl_data` buckets are deliberately left out for that reason: one is a
latency-sensitive serve path with no versioning, the other transitions to Deep Archive.
