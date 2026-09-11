locals {
  placeholder_count = var.create_placeholder_object ? 1 : 0

  validate_placeholder_source = var.create_placeholder_object && (var.placeholder_object_source == null || var.placeholder_object_source_hash == null) ? tobool("create_placeholder_object requires both placeholder_object_source and placeholder_object_source_hash.") : true
}
