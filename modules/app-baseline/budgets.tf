resource "aws_budgets_budget" "this" {
  for_each = local.budgets

  name         = "${var.name}-${each.key}"
  budget_type  = each.value.budget_type
  limit_amount = each.value.limit_amount
  limit_unit   = each.value.limit_unit
  time_unit    = each.value.time_unit

  dynamic "notification" {
    for_each = each.value.thresholds

    content {
      comparison_operator        = notification.value.comparison_operator
      threshold                  = notification.value.threshold
      threshold_type             = notification.value.threshold_type
      notification_type          = notification.value.notification_type
      subscriber_email_addresses = var.notification_emails
      subscriber_sns_topic_arns  = var.budget_sns_topic_arns
    }
  }
}
