output "resource_group_arn" {
  description = "ARN of the resource group, null when resource_group_enabled is false."
  value       = one(aws_resourcegroups_group.this[*].arn)
}

output "resource_group_name" {
  description = "Name of the resource group, null when resource_group_enabled is false. This is also its id."
  value       = one(aws_resourcegroups_group.this[*].name)
}

output "anomaly_monitor_arn" {
  description = "ARN of the Cost Explorer anomaly monitor, null when anomaly_detection_enabled is false. Pass it to another subscription to have a second audience watch the same monitor."
  value       = one(aws_ce_anomaly_monitor.this[*].arn)
}

output "anomaly_subscription_arn" {
  description = "ARN of the anomaly subscription, null when anomaly_detection_enabled is false."
  value       = one(aws_ce_anomaly_subscription.this[*].arn)
}

output "budget_names" {
  description = "Budget key to the full budget name AWS stores, for example { \"monthly-warn\" = \"carmodpicker-production-monthly-warn\" }. Empty when no budgets are defined."
  value       = { for suffix, budget in aws_budgets_budget.this : suffix => budget.name }
}

output "budget_arns" {
  description = "Budget key to ARN, for a notification rule or a policy that names a budget."
  value       = { for suffix, budget in aws_budgets_budget.this : suffix => budget.arn }
}
