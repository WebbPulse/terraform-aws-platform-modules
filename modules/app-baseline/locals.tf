locals {
  resource_group_count    = var.resource_group_enabled ? 1 : 0
  anomaly_detection_count = var.anomaly_detection_enabled ? 1 : 0

  # An empty map and an unset attribute are the same thing to the provider, but passing null is
  # the form that plans clean against a resource created without a tags argument, which is what
  # both application estates have in state today (they tag through provider default_tags).
  resource_group_tags = length(var.tags) > 0 ? var.tags : null

  # The Cost Explorer console stores the threshold as a plain decimal string. Both estates wrote
  # "10", so the number is formatted without a trailing ".0" to keep the stored value identical.
  anomaly_threshold_value = format("%g", var.anomaly_threshold)

  # aws_resourcegroups_group takes the query as a JSON document. jsonencode sorts keys, so the
  # rendered string matches what is in state as long as the same fields are present.
  resource_query = jsonencode({
    ResourceTypeFilters = var.resource_group_resource_type_filters
    TagFilters = [
      for key, values in var.resource_group_tag_filters : {
        Key    = key
        Values = values
      }
    ]
  })

  # Budgets are keyed by their suffix so the map is stable and a consumer can add a third one
  # without disturbing the two that exist.
  budgets = {
    for suffix, budget in var.budgets : suffix => budget
  }
}
