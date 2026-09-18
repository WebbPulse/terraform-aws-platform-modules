terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

locals {
  name = "example-production"
}

module "vpc" {
  source = "../../modules/vpc-public"

  name         = "${local.name}-runner"
  cidr_block   = "10.20.0.0/16"
  subnet_count = 2

  enable_s3_gateway_endpoint       = true
  enable_dynamodb_gateway_endpoint = true

  tags = {
    Application = local.name
    Component   = "runner"
  }
}

resource "aws_ecs_cluster" "runner" {
  name = "${local.name}-runner"
}

resource "aws_ecs_task_definition" "plan" {
  family                   = "${local.name}-plan"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "terraform"
    image     = "public.ecr.aws/docker/library/alpine:3.20"
    essential = true
    command   = ["true"]
  }])
}

output "network_configuration" {
  description = "The network configuration an on-demand RunTask call passes. assign_public_ip must be ENABLED, because this VPC has no NAT gateway and a task with no public IP has no route out at all."
  value = {
    subnets          = module.vpc.public_subnet_ids
    security_groups  = [module.vpc.task_security_group_id]
    assign_public_ip = "ENABLED"
  }
}

output "vpc_id" {
  description = "Id of the VPC the runner tasks launch into."
  value       = module.vpc.vpc_id
}
