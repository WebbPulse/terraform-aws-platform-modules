variables {
  bucket = "example-staging-state"
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition = "aws"
  }
}

run "the_default_policy_is_tls_only_and_nothing_else" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_policy.this) == 1
    error_message = "A bucket policy must be written by default, because the TLS-only deny is on by default and there is no way to express it without one."
  }

  assert {
    condition     = length(jsondecode(local.bucket_policy_json).Statement) == 1
    error_message = "The default policy must carry exactly one statement. Every extra deny is a way for a legitimate writer to be blocked, so the default is the single statement that cannot break a compliant client."
  }

  assert {
    condition     = jsondecode(local.bucket_policy_json).Statement[0].Sid == "DenyNonTLSRequests"
    error_message = "The one default statement must be the TLS-only deny."
  }
}

run "the_tls_only_deny_is_conditioned_on_secure_transport_alone" {
  command = plan

  assert {
    condition     = jsondecode(local.bucket_policy_json).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "The TLS deny must trigger only on aws:SecureTransport false. A deny written any other way, for example on the absence of a header, would also deny requests that did arrive over TLS."
  }

  assert {
    condition     = contains(jsondecode(local.bucket_policy_json).Statement[0].Resource, "arn:aws:s3:::example-staging-state") && contains(jsondecode(local.bucket_policy_json).Statement[0].Resource, "arn:aws:s3:::example-staging-state/*")
    error_message = "The TLS deny must name both the bucket and its objects. A deny on only one of the two leaves either the bucket level calls or the object calls reachable over plain HTTP."
  }
}

run "nothing_in_the_default_policy_blocks_a_conditional_write" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(local.bucket_policy_json).Statement : s
      if s.Effect == "Deny" && contains(keys(s.Condition), "StringNotEquals")
    ]) == 0
    error_message = "The default policy must carry no deny that inspects a request header. The S3 backend's native lockfile is a plain PutObject made with If-None-Match, so any header based deny on PutObject breaks state locking and the run fails at lock acquisition rather than at the write."
  }

  assert {
    condition = length([
      for s in jsondecode(local.bucket_policy_json).Statement : s
      if s.Effect == "Deny" && s.Action == "s3:PutObject"
    ]) == 0
    error_message = "No PutObject deny may be on by default. The lockfile write and the state write are both plain PutObject calls, so a default deny on that action makes the bucket unusable as a backend."
  }
}

run "the_deny_unencrypted_upload_statement_is_opt_in_and_matches_the_bucket_default" {
  command = plan

  variables {
    enable_deny_unencrypted_uploads_policy = true
  }

  assert {
    condition     = length([for s in jsondecode(local.bucket_policy_json).Statement : s if s.Sid == "DenyUnencryptedObjectUploads"]) == 1
    error_message = "The encryption deny must be addable, since an estate under an audit that requires the header needs a way to enforce it."
  }

  assert {
    condition     = [for s in jsondecode(local.bucket_policy_json).Statement : s if s.Sid == "DenyUnencryptedObjectUploads"][0].Condition.StringNotEquals["s3:x-amz-server-side-encryption"] == "AES256"
    error_message = "The deny must name the algorithm the bucket default actually applies, AES256 here. Naming aws:kms on an SSE-S3 bucket denies every upload, including the ones the bucket would have encrypted correctly."
  }
}

run "the_encryption_deny_names_kms_on_a_kms_bucket" {
  command = plan

  variables {
    enable_deny_unencrypted_uploads_policy = true
    kms_key_arn                            = "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
  }

  assert {
    condition     = [for s in jsondecode(local.bucket_policy_json).Statement : s if s.Sid == "DenyUnencryptedObjectUploads"][0].Condition.StringNotEquals["s3:x-amz-server-side-encryption"] == "aws:kms"
    error_message = "On a KMS bucket the deny must name aws:kms, tracking the bucket's own default rather than being hard-coded, so the statement and the encryption rule cannot disagree."
  }
}

run "extra_statements_are_merged_and_no_policy_is_written_when_nothing_is_asked_for" {
  command = plan

  variables {
    enable_tls_only_policy = false
    extra_policy_statements = [{
      Sid       = "AllowReaderAccount"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::123456789012:root" }
      Action    = ["s3:GetObject"]
      Resource  = "arn:aws:s3:::example-staging-state/*"
    }]
  }

  assert {
    condition     = length(jsondecode(local.bucket_policy_json).Statement) == 1 && jsondecode(local.bucket_policy_json).Statement[0].Sid == "AllowReaderAccount"
    error_message = "A caller supplied statement must reach the policy on its own, so a cross-account grant can be added without replacing the whole policy or forking the module."
  }
}

run "no_bucket_policy_resource_exists_when_every_statement_is_off" {
  command = plan

  variables {
    enable_tls_only_policy = false
  }

  assert {
    condition     = length(aws_s3_bucket_policy.this) == 0
    error_message = "With no statements the module must write no bucket policy at all rather than an empty one. An empty Statement list is rejected by S3, and adopting a bucket whose policy is managed elsewhere requires leaving the resource out."
  }

  assert {
    condition     = output.bucket_policy_json == null
    error_message = "The bucket_policy_json output must be null when no policy is written, so a consumer can tell the difference between an empty policy and none."
  }
}

run "the_read_policies_are_scoped_to_this_bucket_and_carry_no_wildcard_action" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(output.read_write_policy_json).Statement :
      alltrue([for r in s.Resource : startswith(r, "arn:aws:s3:::example-staging-state")])
    ])
    error_message = "Every resource in the read-write policy must be this bucket or its objects. A policy that reached other buckets would hand a workspace role access to state it must not be able to read."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.read_write_policy_json).Statement :
      !contains(s.Action, "s3:*")
    ])
    error_message = "The generated policies must never contain s3:* . A wildcard would include bucket level calls like PutBucketPolicy, which lets the holder rewrite the very policy restricting it."
  }

  assert {
    condition = length(setsubtract(
      ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      flatten([for s in jsondecode(output.read_write_policy_json).Statement : s.Action])
    )) == 0
    error_message = "The read-write policy must grant GetObject, PutObject, DeleteObject and ListBucket, which are exactly the four actions the Terraform S3 backend needs to read, write and lock state."
  }
}

run "the_read_only_policy_grants_no_write" {
  command = plan

  assert {
    condition = length([
      for a in flatten([for s in jsondecode(output.read_only_policy_json).Statement : s.Action]) : a
      if startswith(a, "s3:Put") || startswith(a, "s3:Delete")
    ]) == 0
    error_message = "The read-only policy must grant no Put or Delete action. It is the policy handed to a consumer that only reads what the bucket holds, and a write action in it defeats the reason for having two policies."
  }
}

run "the_policies_grant_kms_only_when_the_bucket_uses_a_key" {
  command = plan

  assert {
    condition = length([
      for a in flatten([for s in jsondecode(output.read_write_policy_json).Statement : s.Action]) : a
      if startswith(a, "kms:")
    ]) == 0
    error_message = "On an SSE-S3 bucket the policies must grant no KMS action. There is no key to name, so a kms statement would either need a wildcard resource or fail to render."
  }
}

run "the_kms_grant_names_the_bucket_key_when_one_is_used" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.read_write_policy_json).Statement :
      alltrue([for r in s.Resource : startswith(r, "arn:aws:s3:::example-staging-state") || r == "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"])
    ])
    error_message = "The KMS grant must name the bucket's own key ARN and nothing broader. kms:Decrypt on Resource \"*\" would let the holder decrypt anything in the account that key policies delegate to IAM."
  }

  assert {
    condition = length(setsubtract(
      ["kms:Decrypt", "kms:GenerateDataKey"],
      flatten([for s in jsondecode(output.read_write_policy_json).Statement : s.Action])
    )) == 0
    error_message = "A writer needs both kms:Decrypt and kms:GenerateDataKey on a KMS encrypted bucket. GenerateDataKey alone fails every read, and Decrypt alone fails every write, and both failures surface as an opaque AccessDenied from S3."
  }
}

run "creating_a_key_and_supplying_one_at_once_is_rejected" {
  command = plan

  variables {
    create_kms_key = true
    kms_key_arn    = "arn:aws:kms:us-west-2:123456789012:key/00000000-1111-2222-3333-444444444444"
  }

  expect_failures = [var.create_kms_key]
}
