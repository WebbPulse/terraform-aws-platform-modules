locals {
  placeholder_count = var.create_placeholder_object ? 1 : 0

  # A placeholder with no file to upload only fails at apply time, so refuse it during plan.
  validate_placeholder_source = var.create_placeholder_object && (var.placeholder_object_source == null || var.placeholder_object_source_hash == null) ? tobool("create_placeholder_object requires both placeholder_object_source and placeholder_object_source_hash.") : true
}
