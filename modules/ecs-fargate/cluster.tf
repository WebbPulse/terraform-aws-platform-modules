data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

resource "aws_ecs_cluster" "this" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  tags = var.cluster_tags
}

resource "aws_cloudwatch_log_group" "this" {
  for_each = local.tasks

  name              = each.value.log_group_name
  retention_in_days = each.value.log_retention_days
  kms_key_id        = each.value.log_group_kms_key_id
  tags              = var.log_group_tags
}
