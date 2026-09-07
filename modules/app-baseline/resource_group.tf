# ---------------------------------------------------------------------------
# Resource group, tag based auto discovery.
# Surfaces everything carrying the project's tag in one console view, which is also what the
# Cost Explorer "resource group" filter and the tag editor read.
# ---------------------------------------------------------------------------
resource "aws_resourcegroups_group" "this" {
  count = local.resource_group_count

  name        = var.name
  description = var.resource_group_description
  tags        = local.resource_group_tags

  resource_query {
    query = local.resource_query
  }
}
