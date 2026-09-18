variables {
  name               = "example-staging"
  availability_zones = ["us-west-2a", "us-west-2b"]
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

run "there_is_one_route_table_with_a_default_route_to_the_internet_gateway" {
  command = plan

  override_resource {
    target          = aws_route_table.public
    override_during = plan
    values = {
      id = "rtb-00000000000000000"
    }
  }

  override_resource {
    target          = aws_internet_gateway.this
    override_during = plan
    values = {
      id = "igw-00000000000000000"
    }
  }

  assert {
    condition     = aws_route.internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "The route table must carry a default route. Without it a task in these subnets has a public IP but no path off the VPC, so an image pull hangs until the task times out."
  }

  assert {
    condition     = aws_route.internet.route_table_id == "rtb-00000000000000000"
    error_message = "The default route must be on the module's own route table, which is the one the subnets associate with and the one a gateway endpoint attaches to."
  }

  assert {
    condition     = aws_route.internet.gateway_id == "igw-00000000000000000"
    error_message = "The default route must point at the module's internet gateway. A route to anything else, or to a NAT gateway, would reintroduce the hourly cost this module exists to avoid."
  }
}

run "every_subnet_is_associated_with_the_public_route_table" {
  command = plan

  assert {
    condition     = length(aws_route_table_association.public) == length(aws_subnet.public)
    error_message = "Every subnet must be associated with the public route table. An unassociated subnet falls back to the VPC main route table, which has no internet route, so tasks in that one zone fail while the others work."
  }
}

run "there_is_exactly_one_route_table_so_nothing_routes_through_a_nat" {
  command = plan

  override_resource {
    target          = aws_vpc.this
    override_during = plan
    values = {
      id = "vpc-00000000000000000"
    }
  }

  assert {
    condition     = length(aws_route_table_association.public) == 2 && length(aws_subnet.public) == 2
    error_message = "Every subnet this module creates must be public and share the one route table. A second route table would be the shape a private subnet needs, and a private subnet with no NAT gateway is a subnet with no route out at all."
  }

  assert {
    condition     = aws_internet_gateway.this.vpc_id == "vpc-00000000000000000"
    error_message = "The internet gateway must be attached to this VPC. It is the only egress path here, so an unattached gateway leaves every task unable to pull its image."
  }
}

run "no_vpc_endpoints_are_created_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 0
    error_message = "No VPC endpoint may be created by default. An interface endpoint bills hourly per zone, and this module's whole cost argument is that a public IP replaces both NAT and endpoints, so anything billable has to be opt in."
  }
}

run "the_free_gateway_endpoints_can_be_turned_on_and_attach_to_the_route_table" {
  command = plan

  variables {
    enable_s3_gateway_endpoint       = true
    enable_dynamodb_gateway_endpoint = true
  }

  override_resource {
    target          = aws_route_table.public
    override_during = plan
    values = {
      id = "rtb-00000000000000000"
    }
  }

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 2
    error_message = "Both gateway endpoints must be creatable. They are the only endpoint type AWS does not charge for, so an estate reading S3 or DynamoDB heavily should be able to keep that traffic off the public path for free."
  }

  assert {
    condition     = alltrue([for e in aws_vpc_endpoint.gateway : e.vpc_endpoint_type == "Gateway"])
    error_message = "These endpoints must be Gateway type. An Interface endpoint for the same service costs about 7 USD per zone per month, which is the cost this module was built to avoid."
  }

  assert {
    condition     = alltrue([for e in aws_vpc_endpoint.gateway : contains(e.route_table_ids, "rtb-00000000000000000")])
    error_message = "A gateway endpoint must be associated with the public route table. An unassociated gateway endpoint changes no routing at all and silently does nothing."
  }
}

run "dns_support_and_hostnames_are_on" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "DNS support and hostnames must both default to on. Without resolution nothing in the VPC can look up a regional AWS endpoint, and a gateway VPC endpoint requires hostnames to be usable at all."
  }
}
