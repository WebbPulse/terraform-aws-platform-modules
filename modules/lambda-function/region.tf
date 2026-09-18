data "aws_region" "current" {
  count = local.any_event_source ? 1 : 0
}
