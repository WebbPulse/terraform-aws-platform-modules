resource "aws_resourcegroups_group" "this" {
  count = local.resource_group_count

  name        = var.name
  description = var.resource_group_description
  tags        = local.resource_group_tags

  resource_query {
    query = local.resource_query
  }
}
