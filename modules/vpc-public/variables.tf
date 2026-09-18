variable "name" {
  description = "Name the VPC and every resource in it is named after, for example \"webbpulse-terraform-staging\". Changing it renames rather than replaces."
  type        = string

  validation {
    condition     = length(var.name) > 0 && length(var.name) <= 100
    error_message = "name must be 1 to 100 characters."
  }
}

variable "cidr_block" {
  description = "IPv4 CIDR block of the VPC. Public subnets are cut from it, so it must be large enough for subnet_newbits times the subnet count. Changing it replaces the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = tonumber(split("/", var.cidr_block)[1]) <= 24
    error_message = "cidr_block must be /24 or larger so there is room to cut public subnets from it."
  }
}

variable "subnet_count" {
  description = "Number of public subnets, one per availability zone, taken from the first subnet_count zones the region offers. Two is enough for an on-demand task to survive one zone being out of capacity."
  type        = number
  default     = 2

  validation {
    condition     = var.subnet_count >= 1 && var.subnet_count <= 6 && floor(var.subnet_count) == var.subnet_count
    error_message = "subnet_count must be a whole number from 1 to 6."
  }
}

variable "availability_zones" {
  description = "Availability zone names to place the subnets in, in order, overriding the region lookup. Null asks the provider for the zones available to the account. A list shorter than subnet_count fails the plan."
  type        = list(string)
  default     = null

  validation {
    condition     = var.availability_zones == null || length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must not repeat a zone."
  }
}

variable "subnet_newbits" {
  description = "Bits added to the VPC prefix length to size each public subnet, passed to cidrsubnet. 8 on a /16 gives /24 subnets. Changing it replaces every subnet."
  type        = number
  default     = 8

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 16 && floor(var.subnet_newbits) == var.subnet_newbits
    error_message = "subnet_newbits must be a whole number from 1 to 16."
  }
}

variable "subnet_cidr_blocks" {
  description = "Explicit CIDR block per subnet, in order, overriding the cidrsubnet calculation. Null computes them. A list shorter than subnet_count fails the plan."
  type        = list(string)
  default     = null

  validation {
    condition     = var.subnet_cidr_blocks == null || alltrue([for c in var.subnet_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "every entry in subnet_cidr_blocks must be a valid IPv4 CIDR block."
  }
}

variable "map_public_ip_on_launch" {
  description = "Give an instance or task launched into these subnets a public IPv4 address by default. A Fargate task still needs assign_public_ip ENABLED in its network configuration; this setting does not reach it."
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "DNS resolution inside the VPC. Off means nothing in the VPC can resolve an AWS API endpoint, so leave it on."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Public DNS hostnames for instances with a public IP. Required for a gateway VPC endpoint to be usable, and harmless otherwise."
  type        = bool
  default     = true
}

variable "instance_tenancy" {
  description = "Tenancy of instances launched into the VPC: \"default\" or \"dedicated\". Fargate requires default."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "dedicated"], var.instance_tenancy)
    error_message = "instance_tenancy must be default or dedicated."
  }
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway VPC endpoint and associate it with the public route table. Gateway endpoints cost nothing, so this keeps S3 traffic off the public path without adding a bill."
  type        = bool
  default     = false
}

variable "enable_dynamodb_gateway_endpoint" {
  description = "Create the DynamoDB gateway VPC endpoint and associate it with the public route table. Free, like the S3 one."
  type        = bool
  default     = false
}

variable "task_security_group_name" {
  description = "Name of the egress-only security group for on-demand tasks. Null names it \"<name>-tasks\"."
  type        = string
  default     = null
}

variable "task_security_group_egress_cidr_blocks" {
  description = "IPv4 CIDR blocks the task security group may reach. The default is everywhere, which is what an image pull from a public registry and a call to a regional AWS endpoint need."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.task_security_group_egress_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "every entry in task_security_group_egress_cidr_blocks must be a valid IPv4 CIDR block."
  }
}

variable "task_security_group_egress_ipv6_cidr_blocks" {
  description = "IPv6 CIDR blocks the task security group may reach. Empty leaves IPv6 egress unwritten, which is the right default on a VPC with no IPv6 block."
  type        = list(string)
  default     = []
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to a CloudWatch log group this module creates, with its own role. Off by default: a VPC that only carries short lived task traffic pays ingestion for records nobody reads."
  type        = bool
  default     = false
}

variable "flow_logs_traffic_type" {
  description = "Traffic the flow log captures: ACCEPT, REJECT or ALL. Only meaningful with enable_flow_logs."
  type        = string
  default     = "REJECT"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_logs_traffic_type)
    error_message = "flow_logs_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "flow_logs_retention_in_days" {
  description = "Retention of the flow log group. Only meaningful with enable_flow_logs."
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_in_days)
    error_message = "flow_logs_retention_in_days must be one of the retention periods CloudWatch Logs accepts."
  }
}

variable "flow_logs_kms_key_arn" {
  description = "KMS key ARN encrypting the flow log group. Null leaves the group on the CloudWatch Logs default encryption."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for every resource this module creates, on top of any provider default_tags."
  type        = map(string)
  default     = {}
}
