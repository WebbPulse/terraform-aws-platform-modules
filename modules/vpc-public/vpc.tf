data "aws_availability_zones" "available" {
  count = var.availability_zones == null ? 1 : 0

  state = "available"
}

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = var.enable_dns_support
  enable_dns_hostnames = var.enable_dns_hostnames
  instance_tenancy     = var.instance_tenancy

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  for_each = local.subnet_cidrs

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = local.subnet_zones[each.key]
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(var.tags, { Name = "${var.name}-public-${local.subnet_zones[each.key]}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-locked" })
}

resource "aws_security_group" "tasks" {
  name        = local.task_security_group_name
  description = "Egress only security group for on-demand tasks in ${var.name}. No ingress: nothing dials a task, the task dials out."
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = local.task_security_group_name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "tasks_ipv4" {
  for_each = toset(var.task_security_group_egress_cidr_blocks)

  security_group_id = aws_security_group.tasks.id
  description       = "All outbound traffic to ${each.value}"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "tasks_ipv6" {
  for_each = toset(var.task_security_group_egress_ipv6_cidr_blocks)

  security_group_id = aws_security_group.tasks.id
  description       = "All outbound traffic to ${each.value}"
  ip_protocol       = "-1"
  cidr_ipv6         = each.value

  tags = var.tags
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = local.gateway_endpoints

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}
