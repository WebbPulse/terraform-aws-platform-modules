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
}
