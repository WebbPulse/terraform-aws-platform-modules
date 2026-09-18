# terraform-aws-s3-bucket

A general purpose private S3 bucket: public access block, bucket owner enforced ownership,
versioning, server-side encryption with SSE-S3 or a KMS key the module takes or creates, a
TLS-only bucket policy, optional lifecycle rules, optional EventBridge notifications and CORS,
and ready-made read-only and read-write IAM policy documents scoped to the bucket and its key.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/s3-bucket`.

## Usage

```hcl
module "state" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/s3-bucket"
  version = "~> 2.23"

  bucket = "example-production-terraform-state"

  create_kms_key = true

  lifecycle_rules = {
    expire-noncurrent-state = {
      noncurrent_version_expiration_days     = 365
      newer_noncurrent_versions              = 10
      abort_incomplete_multipart_upload_days = 7
    }
  }
}

resource "aws_iam_role_policy" "workspace_state" {
  name   = "terraform-state"
  role   = aws_iam_role.workspace.id
  policy = module.state.read_write_policy_json
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `bucket` | Bucket name; changing it replaces the bucket | required |
| `force_destroy` | Let Terraform delete a bucket that still holds objects | `false` |
| `versioning_status` | `Enabled` or `Suspended` | `"Enabled"` |
| `object_ownership` | Ownership controls setting; `BucketOwnerEnforced` turns ACLs off | `"BucketOwnerEnforced"` |
| `kms_key_arn` | Existing KMS key encrypting every object | `null` |
| `create_kms_key` | Create a customer managed key for this bucket | `false` |
| `kms_key_description` | Description of the created key | `null` |
| `kms_key_rotation_enabled` | Yearly rotation of the created key | `true` |
| `kms_key_deletion_window_in_days` | Days before a scheduled key deletion completes | `30` |
| `kms_key_extra_principal_arns` | Principals the created key grants encrypt and decrypt to | `[]` |
| `kms_key_policy_json` | Complete policy JSON replacing the generated key policy | `null` |
| `create_kms_key_alias` | Create an alias for the created key | `true` |
| `kms_key_alias` | Alias name, with or without the `alias/` prefix | `null` |
| `bucket_key_enabled` | S3 Bucket Keys on the encryption rule | `true` |
| `enable_tls_only_policy` | Deny every request that did not arrive over TLS | `true` |
| `enable_deny_unencrypted_uploads_policy` | Deny a PutObject without the encryption header | `false` |
| `extra_policy_statements` | Additional bucket policy statements, merged in order | `[]` |
| `lifecycle_rules` | Lifecycle rules keyed by rule id | `{}` |
| `enable_eventbridge_notifications` | Send object events to the default EventBridge bus | `false` |
| `cors_rules` | CORS rules, in order | `[]` |
| `tags` | Tags for the bucket and the created KMS key | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `bucket` | Bucket name |
| `bucket_id` | The same name, under the other convention |
| `bucket_arn` | Bucket ARN with no suffix |
| `bucket_regional_domain_name` | Regional domain name of the bucket |
| `bucket_domain_name` | Global domain name of the bucket |
| `region` | Region the bucket lives in |
| `kms_key_arn` | ARN of the key encrypting the bucket, null on SSE-S3 |
| `kms_key_id` | Id of the created key, null when none was created |
| `kms_key_alias` | Alias of the created key, null when no alias exists |
| `read_only_policy_json` | IAM policy JSON granting list and read on this bucket and decrypt on its key |
| `read_write_policy_json` | IAM policy JSON granting read, write, delete and the multipart actions, plus encrypt and decrypt |
| `read_only_policy_statements` | The read-only policy as a statement list rather than JSON |
| `read_write_policy_statements` | The read-write policy as a statement list rather than JSON |
| `bucket_policy_json` | The bucket policy the module wrote, null when none was |

## Gotchas

- **Nothing in the default policy may block a conditional write.** The S3 backend's native
  lockfile, the `use_lockfile` option added in Terraform 1.11, is a plain `PutObject` of
  `<key>.tflock` made with an `If-None-Match` header. It is an ordinary unencrypted-header
  PutObject, so any bucket policy deny that inspects request headers on `s3:PutObject` breaks
  state locking rather than state writing, and the run fails while acquiring the lock with an
  AccessDenied that names no condition. That is why `enable_deny_unencrypted_uploads_policy`
  defaults to false and the only default statement is the TLS-only deny, which triggers on
  `aws:SecureTransport` alone and never on a header. A test asserts that the default policy
  contains no header-conditioned deny and no `s3:PutObject` deny at all.
- This is a general purpose bucket. It carries no artifact-specific behaviour: no placeholder
  object, no fixed lifecycle rule, no assumption about what the keys look like. A bucket holding
  Terraform state, config tarballs and a module registry has three different retention needs, so
  the rules are a map the caller writes and nothing is expired by default.
- `create_kms_key` and `kms_key_arn` are mutually exclusive, and the module rejects both at once.
  Two keys on one bucket means objects written under whichever one fell out of use become
  unreadable when it is deleted.
- With no key the bucket is SSE-S3, which costs nothing per request. A Terraform run reads and
  writes state on every plan, so a KMS key bills every one of those requests; `bucket_key_enabled`
  defaults to true to cut that charge by orders of magnitude when a key is used anyway.
- The generated key policy grants the account root `kms:*`. That statement is not optional in
  practice: an IAM policy in the account has no effect on a KMS key unless the key policy
  delegates to IAM, so a key without it cannot be managed or fixed afterwards. Replacing the
  policy with `kms_key_policy_json` can lock the key out of its own account, and
  `bypass_policy_lockout_safety_check` is off so AWS refuses the most obvious version of that
  mistake.
- The `read_only_policy_json` and `read_write_policy_json` outputs are scoped to this bucket, its
  objects and its key, and contain no `s3:*`. A wildcard would include bucket-level calls such as
  `PutBucketPolicy`, which lets the holder rewrite the policy restricting it. On a KMS bucket the
  read-write policy grants both `kms:Decrypt` and `kms:GenerateDataKey`; either one alone fails
  half the operations with an opaque AccessDenied from S3 rather than from KMS.
- The encryption deny, when turned on, names the algorithm the bucket default actually applies:
  `AES256` on an SSE-S3 bucket and `aws:kms` on a KMS one. It tracks the bucket rather than being
  fixed, because naming `aws:kms` on an SSE-S3 bucket denies every upload including the ones the
  bucket would have encrypted correctly.
- `object_ownership` defaults to `BucketOwnerEnforced`, which disables ACLs entirely. With ACLs
  live, an object written by another account stays owned by that account and the bucket owner
  cannot read it. The other two values exist only to adopt a bucket that still relies on ACLs.
- The bucket is versioned and `force_destroy` is false, so a destroy fails until the objects and
  their noncurrent versions are removed on purpose. On a state bucket that is the intended
  outcome.
- Setting `enable_tls_only_policy = false` with no extra statements writes no bucket policy
  resource at all, rather than an empty one. S3 rejects an empty `Statement` list, and leaving the
  resource out is also how a bucket whose policy is managed elsewhere gets adopted.
- Replication, object lock, request metrics, access logging and inventory are out of scope.
