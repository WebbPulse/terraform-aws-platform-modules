variables {
  bucket = "example-staging-lambda-artifacts"
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

run "both_bucket_name_outputs_publish_the_name_the_consumer_gave" {
  command = plan

  assert {
    condition     = output.bucket == "example-staging-lambda-artifacts"
    error_message = "bucket must publish the plain bucket name. The Portfolio estate wires it into a Lambda's s3_bucket and into a GitHub Actions deploy variable, so anything but the plain name breaks the deploy job's upload target."
  }
}

run "bucket_id_publishes_the_same_name_under_the_other_convention" {
  command = plan

  override_resource {
    target          = aws_s3_bucket.this
    override_during = plan
    values = {
      id = "example-staging-lambda-artifacts"
    }
  }

  assert {
    condition     = output.bucket_id == "example-staging-lambda-artifacts"
    error_message = "bucket_id must resolve to the bucket name, because for S3 the id is the name. A consumer that wires bucket_id into a Lambda's s3_bucket and bucket into the deploy pipeline must not end up reading from one bucket and uploading to another."
  }
}

run "the_bucket_arn_output_resolves_to_the_arn_the_grant_is_written_against" {
  command = plan

  override_resource {
    target          = aws_s3_bucket.this
    override_during = plan
    values = {
      arn = "arn:aws:s3:::example-staging-lambda-artifacts"
    }
  }

  assert {
    condition     = output.bucket_arn == "arn:aws:s3:::example-staging-lambda-artifacts"
    error_message = "bucket_arn must be the bucket's own ARN with no suffix. The Portfolio deploy role grants s3:PutObject on this ARN and on the same ARN with \"/*\" appended, so a value that already carried a suffix would grant on the wrong resource twice."
  }
}

run "the_placeholder_outputs_resolve_once_the_object_exists" {
  command = plan

  variables {
    create_placeholder_object      = true
    placeholder_object_source      = "./tests/fixtures/placeholder.zip"
    placeholder_object_source_hash = "WgCLkeshgGL+TaQ+EjjxcyTQB07BQXmrH4MyGyuP38Y="
  }

  override_resource {
    target          = aws_s3_object.placeholder
    override_during = plan
    values = {
      version_id = "3sL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vE"
      etag       = "d41d8cd98f00b204e9800998ecf8427e"
    }
  }

  assert {
    condition     = output.placeholder_object_version_id == "3sL4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY+MTRCxf3vE"
    error_message = "placeholder_object_version_id must publish the object's version once one exists. A Lambda that pins s3_object_version reads this value, and a null here would leave the function pointing at whatever version is current."
  }

  assert {
    condition     = output.placeholder_object_etag == "d41d8cd98f00b204e9800998ecf8427e"
    error_message = "placeholder_object_etag must publish the object's etag once one exists, so a consumer can detect that the uploaded stub differs from the one it built without downloading it."
  }
}

run "the_full_portfolio_shape_plans_to_the_expected_resource_set" {
  command = plan

  variables {
    bucket = "example-staging-lambda-artifacts"

    lifecycle_rule_id                      = "expire-noncurrent"
    noncurrent_version_expiration_days     = 30
    abort_incomplete_multipart_upload_days = 7

    enable_sse = true

    create_placeholder_object      = true
    placeholder_object_key         = "backend/placeholder.zip"
    placeholder_object_source      = "./tests/fixtures/placeholder.zip"
    placeholder_object_source_hash = "WgCLkeshgGL+TaQ+EjjxcyTQB07BQXmrH4MyGyuP38Y="
  }

  assert {
    condition     = length(aws_s3_bucket_server_side_encryption_configuration.this) == 1 && length(aws_s3_object.placeholder) == 1
    error_message = "The exact shape the Portfolio estate passes must plan to a bucket with an encryption rule and a placeholder object. This is the combination in production, so it is the one a refactor is most likely to break silently."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "The production shape must still block every route to public access. A bucket that holds the code a Lambda executes is the last place an accidental public read should be possible."
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Enabled"
    error_message = "The production shape must be versioned, because that is what makes a bad release recoverable by pointing the function back at the previous object version."
  }
}
