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

run "no_placeholder_object_is_created_by_default" {
  command = plan

  assert {
    condition     = length(aws_s3_object.placeholder) == 0
    error_message = "create_placeholder_object must default to false. A bucket adopted from an estate that already deploys real packages must not have a stub object appear in it, because a Lambda pinned to that key would serve the stub."
  }

  assert {
    condition     = output.placeholder_object_key == null
    error_message = "placeholder_object_key must be null rather than an error when no placeholder is created, so a consumer can feed it into a Lambda's s3_key and test it for null in one expression."
  }

  assert {
    condition     = output.placeholder_object_version_id == null
    error_message = "placeholder_object_version_id must be null when no placeholder exists. A Lambda that pins s3_object_version needs to be able to tell the difference between no object and an unknown version."
  }

  assert {
    condition     = output.placeholder_object_etag == null
    error_message = "placeholder_object_etag must be null when no placeholder exists, for the same reason the other two are: the outputs are the module's whole interface for the optional object."
  }
}

run "a_placeholder_is_uploaded_to_the_documented_key_when_asked_for" {
  command = plan

  variables {
    create_placeholder_object      = true
    placeholder_object_source      = "./tests/fixtures/placeholder.zip"
    placeholder_object_source_hash = "WgCLkeshgGL+TaQ+EjjxcyTQB07BQXmrH4MyGyuP38Y="
  }

  assert {
    condition     = length(aws_s3_object.placeholder) == 1
    error_message = "Turning create_placeholder_object on must create exactly one object, so a Lambda pointed at this bucket has something to reference before the pipeline has ever run."
  }

  assert {
    condition     = one(aws_s3_object.placeholder[*].key) == "backend/placeholder.zip"
    error_message = "The key must default to backend/placeholder.zip. Both estates hardwire this key into the Lambda's s3_key, so changing the default replaces the object and points the function at a key that no longer exists."
  }

  assert {
    condition     = one(aws_s3_object.placeholder[*].source_hash) == "WgCLkeshgGL+TaQ+EjjxcyTQB07BQXmrH4MyGyuP38Y="
    error_message = "source_hash must be the base64 SHA256 the consumer passed. Terraform re-uploads on a change to it, so a dropped hash means an edited placeholder is never actually uploaded."
  }

  assert {
    condition     = output.placeholder_object_key == "backend/placeholder.zip"
    error_message = "placeholder_object_key must publish the key rather than null once an object exists: it is the value a consumer feeds straight into the Lambda's s3_key argument."
  }
}

run "the_placeholder_lands_in_the_bucket_this_module_creates" {
  command = plan

  variables {
    create_placeholder_object      = true
    placeholder_object_source      = "./tests/fixtures/placeholder.zip"
    placeholder_object_source_hash = "WgCLkeshgGL+TaQ+EjjxcyTQB07BQXmrH4MyGyuP38Y="
  }

  override_resource {
    target          = aws_s3_bucket.this
    override_during = plan
    values = {
      id = "example-staging-lambda-artifacts"
    }
  }

  assert {
    condition     = one(aws_s3_object.placeholder[*].bucket) == "example-staging-lambda-artifacts"
    error_message = "The placeholder must land in the bucket this module creates rather than any other, because the Lambda reads its code from the bucket id this same module outputs and a mismatch leaves the function pointing at a key that does not exist."
  }
}

run "the_placeholder_key_is_a_passthrough" {
  command = plan

  variables {
    create_placeholder_object      = true
    placeholder_object_key         = "lambda/bootstrap.zip"
    placeholder_object_source      = "./tests/fixtures/placeholder.zip"
    placeholder_object_source_hash = "WgCLkeshgGL+TaQ+EjjxcyTQB07BQXmrH4MyGyuP38Y="
  }

  assert {
    condition     = one(aws_s3_object.placeholder[*].key) == "lambda/bootstrap.zip"
    error_message = "An estate that lays its artifacts out differently must be able to choose the key, since the key is what the Lambda references and the module has no say in how the deploy pipeline names its packages."
  }

  assert {
    condition     = output.placeholder_object_key == "lambda/bootstrap.zip"
    error_message = "The output must follow the variable rather than the default, or a consumer wiring the output into s3_key would point the function at a key that was never uploaded."
  }
}

run "the_placeholder_object_carries_the_same_tags_as_the_bucket" {
  command = plan

  variables {
    create_placeholder_object      = true
    placeholder_object_source      = "./tests/fixtures/placeholder.zip"
    placeholder_object_source_hash = "WgCLkeshgGL+TaQ+EjjxcyTQB07BQXmrH4MyGyuP38Y="

    tags = {
      Project     = "example"
      Environment = "staging"
    }
  }

  assert {
    condition     = one(aws_s3_object.placeholder[*].tags) == tomap({ Project = "example", Environment = "staging" })
    error_message = "The placeholder object must carry the same tags as the bucket. Object level tags are what a cost or inventory report attributes to the project, and an untagged object shows up as unowned."
  }
}

run "an_empty_placeholder_key_is_rejected" {
  command = plan

  variables {
    placeholder_object_key = ""
  }

  expect_failures = [var.placeholder_object_key]
}
