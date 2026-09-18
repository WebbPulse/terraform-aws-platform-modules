# terraform-aws-vpc-public

A VPC with public subnets only: an internet gateway, one public route table, DNS support and
hostnames on, a locked down default security group, and an egress-only security group for
on-demand tasks. No NAT gateway, no private subnets, and no VPC endpoints unless asked for.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/vpc-public`.

## Usage

```hcl
module "vpc" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/vpc-public"
  version = "~> 2.23"

  name         = "example-production-runner"
  cidr_block   = "10.20.0.0/16"
  subnet_count = 2

  enable_s3_gateway_endpoint       = true
  enable_dynamodb_gateway_endpoint = true
}
```

A Fargate task launched into it takes the subnet list, the task security group, and
`assign_public_ip = "ENABLED"`:

```hcl
network_configuration {
  subnets          = module.vpc.public_subnet_ids
  security_groups  = [module.vpc.task_security_group_id]
  assign_public_ip = true
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | Name the VPC and every resource in it is named after | required |
| `cidr_block` | IPv4 CIDR block of the VPC | `"10.0.0.0/16"` |
| `subnet_count` | Number of public subnets, one per availability zone | `2` |
| `availability_zones` | Zone names in order, overriding the region lookup | `null` |
| `subnet_newbits` | Bits added to the VPC prefix to size each subnet | `8` |
| `subnet_cidr_blocks` | Explicit CIDR per subnet, overriding the calculation | `null` |
| `map_public_ip_on_launch` | Hand out a public IPv4 address by default | `true` |
| `enable_dns_support` | DNS resolution inside the VPC | `true` |
| `enable_dns_hostnames` | Public DNS hostnames for instances with a public IP | `true` |
| `instance_tenancy` | `default` or `dedicated`; Fargate requires default | `"default"` |
| `enable_s3_gateway_endpoint` | Create the free S3 gateway endpoint | `false` |
| `enable_dynamodb_gateway_endpoint` | Create the free DynamoDB gateway endpoint | `false` |
| `task_security_group_name` | Name of the egress-only group; null names it `<name>-tasks` | `null` |
| `task_security_group_egress_cidr_blocks` | IPv4 destinations the task group may reach | `["0.0.0.0/0"]` |
| `task_security_group_egress_ipv6_cidr_blocks` | IPv6 destinations; empty writes no IPv6 rule | `[]` |
| `enable_flow_logs` | Flow logs to a CloudWatch group this module creates | `false` |
| `flow_logs_traffic_type` | `ACCEPT`, `REJECT` or `ALL` | `"REJECT"` |
| `flow_logs_retention_in_days` | Retention of the flow log group | `7` |
| `flow_logs_kms_key_arn` | KMS key encrypting the flow log group | `null` |
| `tags` | Tags for every resource the module creates | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `vpc_id` | Id of the VPC |
| `vpc_arn` | ARN of the VPC |
| `vpc_cidr_block` | IPv4 CIDR block of the VPC |
| `public_subnet_ids` | Subnet ids, ordered by availability zone index |
| `public_subnet_ids_by_availability_zone` | Subnet id keyed by zone name |
| `public_subnet_cidr_blocks` | CIDR block of each subnet, in the same order |
| `availability_zones` | Zone of each subnet, in the same order |
| `task_security_group_id` | Id of the egress-only security group |
| `task_security_group_arn` | ARN of the egress-only security group |
| `route_table_id` | Id of the public route table |
| `internet_gateway_id` | Id of the internet gateway |
| `default_security_group_id` | Id of the locked down default security group |
| `gateway_endpoint_ids` | Id of each gateway endpoint, keyed `s3` and `dynamodb` |
| `flow_log_group_name` | Name of the flow log group, null when off |
| `flow_log_id` | Id of the flow log, null when off |

## Gotchas

- This VPC exists so a Fargate task launched on demand can pull its image and reach the AWS APIs
  over a public IP, with no NAT gateway to pay for. A NAT gateway bills about 32 USD per month per
  zone before a byte moves through it, which on a control plane that runs a handful of short tasks
  a day costs more than everything else in the account. A public IP on the task costs nothing.
- `assign_public_ip` must be true in the task's network configuration. There is no NAT and no
  interface endpoint, so a task without a public IP has no route off the VPC at all. It does not
  fail fast: the task reaches the PENDING state and then times out pulling its image, which reads
  as a slow registry rather than a networking mistake.
- An ECR pull from a public IP is authorized through the task's **execution role**, not through a
  VPC endpoint. The execution role needs `ecr:GetAuthorizationToken`,
  `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer` and `ecr:BatchGetImage`, plus
  `logs:CreateLogStream` and `logs:PutLogEvents` for the log driver. Adding an
  `com.amazonaws.<region>.ecr.dkr` interface endpoint instead reintroduces an hourly per-zone
  charge for a path the public IP already covers.
- Only the S3 and DynamoDB gateway endpoints are offered, and both are off by default. Gateway
  endpoints are free; every interface endpoint bills hourly per zone. Turning the two on keeps
  that traffic off the public path at no cost, and a gateway endpoint only affects routing once it
  is associated with a route table, which this module does for you.
- The task security group has all egress and no ingress. Egress is on every protocol rather than
  TCP 443 alone, because a restriction to 443 also blocks DNS on UDP 53 and a task that cannot
  resolve a name never opens a connection. Nothing dials a task, so there is no ingress rule to
  write.
- The VPC default security group is adopted and left with no rules. AWS creates it allowing all
  traffic between its own members, so leaving it unmanaged means anything launched without an
  explicit group silently gets that allowance. Nothing should be placed in it.
- Flow logs are off by default. A VPC carrying only short lived task traffic would pay CloudWatch
  Logs ingestion for records nobody reads, and the default traffic type when they are on is
  `REJECT`, which is the small set worth reading when a task cannot reach something.
- Subnet CIDR blocks are derived from the subnet index, so raising `subnet_count` adds subnets
  without moving the existing ones, but changing `cidr_block` or `subnet_newbits` renumbers and
  therefore replaces every subnet. Pass `subnet_cidr_blocks` to adopt a layout that already exists.
- There are no private subnets and no second route table on purpose. A private subnet in this VPC
  would have no route out at all, since the thing that would give it one is the NAT gateway this
  module refuses to create.
