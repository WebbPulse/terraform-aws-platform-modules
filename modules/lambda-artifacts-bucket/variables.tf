variable "bucket" {
  description = "Name of the artifacts bucket, for example \"myapp-staging-lambda-artifacts\". Changing it replaces the bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket))
    error_message = "bucket must be 3 to 63 characters of lowercase letters, digits, hyphens and dots, starting and ending with a letter or digit."
  }
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket while it still holds objects. Artifact buckets are versioned, so leaving this false means a destroy fails until the objects are removed on purpose."
  type        = bool
  default     = false
}

variable "lifecycle_rule_id" {
  description = "Id of the single lifecycle rule that expires noncurrent artifacts and aborts stalled multipart uploads. Changing it rewrites the rule in place."
  type        = string
  default     = "expire-noncurrent-artifacts"

  validation {
    condition     = length(var.lifecycle_rule_id) > 0 && length(var.lifecycle_rule_id) <= 255
    error_message = "lifecycle_rule_id must be 1 to 255 characters."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days a noncurrent artifact version is kept before it is deleted."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1 && floor(var.noncurrent_version_expiration_days) == var.noncurrent_version_expiration_days
    error_message = "noncurrent_version_expiration_days must be a whole number of at least 1."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Days after a multipart upload starts before S3 aborts it and reclaims the parts."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_upload_days >= 1 && floor(var.abort_incomplete_multipart_upload_days) == var.abort_incomplete_multipart_upload_days
    error_message = "abort_incomplete_multipart_upload_days must be a whole number of at least 1."
  }
}

variable "enable_sse" {
  description = "Create an aws_s3_bucket_server_side_encryption_configuration with SSE-S3 (AES256). S3 encrypts every new object with AES256 regardless; this only manages the setting explicitly, so the bucket shows a rule rather than the account default. Leave it false on a bucket that has never had one, otherwise adoption adds a resource."
  type        = bool
  default     = false
}

variable "sse_algorithm" {
  description = "Algorithm for the encryption rule when enable_sse is true: \"AES256\" for SSE-S3, or \"aws:kms\" with sse_kms_master_key_id set."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "aws:kms", "aws:kms:dsse"], var.sse_algorithm)
    error_message = "sse_algorithm must be AES256, aws:kms or aws:kms:dsse."
  }
}

variable "sse_kms_master_key_id" {
  description = "KMS key id or ARN for the encryption rule, only meaningful with a KMS sse_algorithm. Null leaves it unset, which is what an AES256 rule stores."
  type        = string
  default     = null
}

variable "sse_bucket_key_enabled" {
  description = "S3 Bucket Keys on the encryption rule, which cut KMS request cost. Null leaves it unset; false is what a rule written without the attribute stores."
  type        = bool
  default     = null
}

variable "versioning_status" {
  description = "Versioning state of the bucket: \"Enabled\" or \"Suspended\". Versioning is what the noncurrent-version expiry rule acts on, so \"Enabled\" is the shape this module is built for."
  type        = string
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Suspended"], var.versioning_status)
    error_message = "versioning_status must be Enabled or Suspended."
  }
}

variable "create_placeholder_object" {
  description = "Upload a placeholder artifact so a Lambda pointed at this bucket has an object to reference before the first real deploy. The zip itself is built by the consumer, which passes placeholder_object_source and placeholder_object_source_hash."
  type        = bool
  default     = false
}

variable "placeholder_object_key" {
  description = "Key of the placeholder object. Changing it replaces the object."
  type        = string
  default     = "backend/placeholder.zip"

  validation {
    condition     = length(var.placeholder_object_key) > 0
    error_message = "placeholder_object_key must not be empty."
  }
}

variable "placeholder_object_source" {
  description = "Path to the local file uploaded as the placeholder object, usually data.archive_file.<name>.output_path. Required when create_placeholder_object is true. The path is stored in state as written, so pass it from the calling module rather than letting the path move."
  type        = string
  default     = null
}

variable "placeholder_object_source_hash" {
  description = "Base64 SHA256 of the placeholder file, usually data.archive_file.<name>.output_base64sha256. Terraform re-uploads when it changes. Required when create_placeholder_object is true."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for the bucket and the placeholder object, on top of any provider default_tags."
  type        = map(string)
  default     = {}
}
