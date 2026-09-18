locals {
  zones = var.availability_zones != null ? var.availability_zones : data.aws_availability_zones.available[0].names

  subnet_indexes = range(var.subnet_count)

  subnet_cidrs = {
    for i in local.subnet_indexes : i => var.subnet_cidr_blocks != null ? var.subnet_cidr_blocks[i] : cidrsubnet(var.cidr_block, var.subnet_newbits, i)
  }

  subnet_zones = { for i in local.subnet_indexes : i => local.zones[i] }

  task_security_group_name = coalesce(var.task_security_group_name, "${var.name}-tasks")

  gateway_endpoints = merge(
    var.enable_s3_gateway_endpoint ? { s3 = "s3" } : {},
    var.enable_dynamodb_gateway_endpoint ? { dynamodb = "dynamodb" } : {},
  )

  validate_zone_count = var.availability_zones != null && length(var.availability_zones) < var.subnet_count ? tobool("availability_zones must hold at least subnet_count entries.") : true

  validate_subnet_cidr_count = var.subnet_cidr_blocks != null && length(var.subnet_cidr_blocks) < var.subnet_count ? tobool("subnet_cidr_blocks must hold at least subnet_count entries.") : true
}
