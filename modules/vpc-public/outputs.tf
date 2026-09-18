output "vpc_id" {
  description = "Id of the VPC. This is what a Fargate task's network configuration and any security group in the VPC is written against."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC, for a resource policy or a condition key that names it."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC, the same string the cidr_block input carried."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Ids of the public subnets, ordered by availability zone index. Pass the whole list as a task's subnets so the scheduler can fall back to another zone."
  value       = [for i in local.subnet_indexes : aws_subnet.public[i].id]
}

output "public_subnet_ids_by_availability_zone" {
  description = "Subnet id keyed by availability zone name, for a caller that has to pin a task to one zone."
  value       = { for i, subnet in aws_subnet.public : local.subnet_zones[i] => subnet.id }
}

output "public_subnet_cidr_blocks" {
  description = "CIDR block of each public subnet, ordered the same as public_subnet_ids."
  value       = [for i in local.subnet_indexes : aws_subnet.public[i].cidr_block]
}

output "availability_zones" {
  description = "Availability zone of each public subnet, ordered the same as public_subnet_ids."
  value       = [for i in local.subnet_indexes : local.subnet_zones[i]]
}

output "task_security_group_id" {
  description = "Id of the egress-only security group. This is the only security group an on-demand task needs, and it accepts no inbound traffic."
  value       = aws_security_group.tasks.id
}

output "task_security_group_arn" {
  description = "ARN of the egress-only security group."
  value       = aws_security_group.tasks.arn
}

output "route_table_id" {
  description = "Id of the public route table. A gateway VPC endpoint added outside this module associates with it."
  value       = aws_route_table.public.id
}

output "internet_gateway_id" {
  description = "Id of the internet gateway carrying the default route."
  value       = aws_internet_gateway.this.id
}

output "default_security_group_id" {
  description = "Id of the VPC's default security group, which this module keeps with no rules at all. Nothing should be placed in it."
  value       = aws_default_security_group.this.id
}

output "gateway_endpoint_ids" {
  description = "Id of each gateway VPC endpoint created, keyed \"s3\" and \"dynamodb\". Empty when neither is enabled."
  value       = { for k, endpoint in aws_vpc_endpoint.gateway : k => endpoint.id }
}

output "flow_log_group_name" {
  description = "Name of the flow log group, null when enable_flow_logs is false."
  value       = one(aws_cloudwatch_log_group.flow_logs[*].name)
}

output "flow_log_id" {
  description = "Id of the flow log, null when enable_flow_logs is false."
  value       = one(aws_flow_log.this[*].id)
}
