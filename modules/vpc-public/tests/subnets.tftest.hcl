variables {
  name               = "example-staging"
  availability_zones = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "two_public_subnets_are_cut_from_the_cidr_by_default" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "subnet_count must default to 2. One subnet means a task cannot be placed at all when its single zone is out of Fargate capacity, which is the failure this module exists to avoid paying a NAT gateway to avoid."
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.0.0.0/24" && aws_subnet.public[1].cidr_block == "10.0.1.0/24"
    error_message = "The default /16 with subnet_newbits 8 must cut consecutive /24 subnets. The blocks are computed from the index, so a change in how they are derived renumbers existing subnets and replaces them."
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == "us-west-2a" && aws_subnet.public[1].availability_zone == "us-west-2b"
    error_message = "Subnets must take the availability zones in the order given, because the subnet id list output is ordered by index and a consumer pinning a task to one zone reads that order."
  }
}

run "the_subnet_count_selects_how_many_zones_are_used" {
  command = plan

  variables {
    subnet_count = 3
  }

  assert {
    condition     = length(aws_subnet.public) == 3
    error_message = "subnet_count must drive the number of subnets, so an estate in a region with three usable zones can spread across all of them without editing the module."
  }
}

run "every_subnet_assigns_a_public_ip_on_launch_by_default" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch])
    error_message = "map_public_ip_on_launch must default to true. The whole point of this VPC is that a task reaches ECR and the AWS APIs over its own public IP, and a subnet that hands out no public IP leaves the task with no route out at all."
  }
}

run "explicit_subnet_cidrs_override_the_calculation" {
  command = plan

  variables {
    cidr_block         = "172.31.0.0/16"
    subnet_cidr_blocks = ["172.31.10.0/24", "172.31.20.0/24"]
  }

  assert {
    condition     = aws_subnet.public[0].cidr_block == "172.31.10.0/24" && aws_subnet.public[1].cidr_block == "172.31.20.0/24"
    error_message = "Explicit CIDR blocks must be a passthrough, so a VPC adopted from an existing layout keeps the blocks it already has rather than being renumbered onto the cidrsubnet grid."
  }
}

run "an_oversized_subnet_count_is_rejected" {
  command = plan

  variables {
    subnet_count = 7
  }

  expect_failures = [var.subnet_count]
}

run "a_zero_subnet_count_is_rejected" {
  command = plan

  variables {
    subnet_count = 0
  }

  expect_failures = [var.subnet_count]
}

run "a_malformed_cidr_block_is_rejected" {
  command = plan

  variables {
    cidr_block = "10.0.0.0/33"
  }

  expect_failures = [var.cidr_block]
}

run "a_cidr_block_too_small_to_subnet_is_rejected" {
  command = plan

  variables {
    cidr_block = "10.0.0.0/28"
  }

  expect_failures = [var.cidr_block]
}

run "a_repeated_availability_zone_is_rejected" {
  command = plan

  variables {
    availability_zones = ["us-west-2a", "us-west-2a"]
  }

  expect_failures = [var.availability_zones]
}
