locals {
  # Full table names, keyed the same way as var.tables so every reference below and every output
  # stays on the consumer's short keys.
  table_names = {
    for key, table in var.tables : key => var.name_prefix == "" ? key : "${var.name_prefix}-${key}"
  }

  # Per-table tags: the optional Name tag first, then the module-wide tags, then the table's own,
  # so the more specific value wins. An empty result is passed to the provider as null rather than
  # {}, which is how a table that never set tags is stored; setting {} explicitly would plan a
  # change on adoption.
  table_tags = {
    for key, table in var.tables : key => merge(
      var.name_tag ? { Name = local.table_names[key] } : {},
      var.tags,
      table.tags,
    )
  }

  # Streams, resolved per table. A table's own stream_view_type wins and turns its stream on by
  # itself; null falls back to the module-wide stream_enabled and stream_view_type pair. A consumer
  # that sets no per-table value therefore plans exactly what it has today, which is what keeps this
  # additive for every existing call.
  #
  # The two are resolved together rather than inline on the resource because they have to agree:
  # the provider wants stream_view_type set when stream_enabled is true and unset when it is false,
  # and a table that inherits a module-wide stream_enabled = false must send null rather than a
  # leftover view type.
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
