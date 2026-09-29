locals {
  resource_group_count    = var.resource_group_enabled ? 1 : 0
  anomaly_detection_count = var.anomaly_detection_enabled ? 1 : 0
  anomaly_monitor_count   = var.anomaly_detection_enabled && var.anomaly_monitor_arn == null ? 1 : 0

  anomaly_monitor_arn = var.anomaly_monitor_arn != null ? var.anomaly_monitor_arn : one(aws_ce_anomaly_monitor.this[*].arn)

  resource_group_tags = length(var.tags) > 0 ? var.tags : null

  anomaly_threshold_value = format("%g", var.anomaly_threshold)

  resource_query = jsonencode({
    ResourceTypeFilters = var.resource_group_resource_type_filters
    TagFilters = [
      for key, values in var.resource_group_tag_filters : {
        Key    = key
        Values = values
      }
    ]
  })

  budgets = {
    for suffix, budget in var.budgets : suffix => budget
  }
}
