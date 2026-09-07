# ---------------------------------------------------------------------------
# Cost anomaly detection. Free, and the earliest warning an account gets that something started
# costing money on its own. The monitor watches one dimension; the subscription decides who hears
# about it and how large an anomaly has to be.
# ---------------------------------------------------------------------------
resource "aws_ce_anomaly_monitor" "this" {
  count = local.anomaly_detection_count

  name              = var.name
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = var.anomaly_monitor_dimension
}

resource "aws_ce_anomaly_subscription" "this" {
  count = local.anomaly_detection_count

  name      = var.name
  frequency = var.anomaly_frequency

  monitor_arn_list = [aws_ce_anomaly_monitor.this[0].arn]

  dynamic "subscriber" {
    for_each = var.notification_emails

    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  dynamic "subscriber" {
    for_each = var.anomaly_sns_topic_arns

    content {
      type    = "SNS"
      address = subscriber.value
    }
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [local.anomaly_threshold_value]
    }
  }
}
