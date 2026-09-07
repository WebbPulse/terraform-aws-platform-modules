# The single notification target every alarm in this module points at. Each address in
# notification_emails gets an email subscription, and AWS sends that address a confirmation link
# on the first apply. Until the address confirms, the subscription sits pending and delivers
# nothing, so a new consumer should expect one confirmation email per address.
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
