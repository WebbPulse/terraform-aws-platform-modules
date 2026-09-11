resource "aws_sns_topic" "alarms" {
  name = local.topic_name
  tags = merge(var.tags, var.sns_topic_tags)
}

resource "aws_sns_topic_subscription" "email" {
  for_each = local.subscriptions

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}
