locals {
  table_names = {
    for key, table in var.tables : key => var.name_prefix == "" ? key : "${var.name_prefix}-${key}"
  }

  table_tags = {
    for key, table in var.tables : key => merge(
      var.name_tag ? { Name = local.table_names[key] } : {},
      var.tags,
      table.tags,
    )
  }

  stream_view_type = {
    for key, table in var.tables : key => (
      table.stream_view_type != null ? table.stream_view_type :
      var.stream_enabled ? var.stream_view_type : null
    )
  }

  stream_enabled = {
    for key, table in var.tables : key => local.stream_view_type[key] != null
  }
}
