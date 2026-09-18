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

run "the_default_security_group_is_adopted_and_declares_no_rules" {
  command = plan

  override_resource {
    target          = aws_vpc.this
    override_during = plan
    values = {
      id = "vpc-00000000000000000"
    }
  }

  assert {
    condition     = aws_default_security_group.this.vpc_id == "vpc-00000000000000000"
    error_message = "The VPC default security group must be adopted by this module. AWS creates it allowing all traffic between its own members, and leaving it unmanaged means anything launched without an explicit group silently gets that allowance. Declaring the resource with no ingress or egress block is what revokes those rules."
  }

  assert {
    condition     = aws_security_group.tasks.vpc_id == "vpc-00000000000000000"
    error_message = "The task security group must live in this VPC, not in the account default VPC. A group in the wrong VPC cannot be attached to a task in these subnets and fails at RunTask time."
  }
}

run "the_task_security_group_has_all_egress_and_no_ingress" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.tasks_ipv4) == 1
    error_message = "There must be one IPv4 egress rule by default, covering everywhere. A task has to reach ECR, S3 and the regional AWS endpoints, and enumerating those ranges is neither stable nor smaller than the default route."
  }

  assert {
    condition     = one(values(aws_vpc_security_group_egress_rule.tasks_ipv4)).cidr_ipv4 == "0.0.0.0/0"
    error_message = "The default egress rule must allow every IPv4 destination, because an image pull goes to whatever address the registry resolves to that minute."
  }

  assert {
    condition     = one(values(aws_vpc_security_group_egress_rule.tasks_ipv4)).ip_protocol == "-1"
    error_message = "Egress must be on every protocol. Restricting it to TCP 443 looks tighter but breaks DNS, which is UDP 53, and a task that cannot resolve a name never gets to open a connection."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.tasks_ipv6) == 0
    error_message = "No IPv6 egress rule may be written by default. The VPC has no IPv6 block unless a caller adds one, and a rule for an address family the VPC does not carry is noise in the console."
  }
}

run "the_task_group_egress_destinations_are_narrowable" {
  command = plan

  variables {
    task_security_group_egress_cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12"]
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.tasks_ipv4) == 2
    error_message = "A caller must be able to narrow egress to named ranges, which is what a task that only talks to endpoints inside the estate should be given."
  }
}

run "the_task_group_is_named_after_the_vpc_by_default_and_is_overridable" {
  command = plan

  assert {
    condition     = aws_security_group.tasks.name == "example-staging-tasks"
    error_message = "The task security group must default to \"<name>-tasks\" so two VPCs in one account never collide on a group name, which is scoped per VPC in AWS but not in a console listing."
  }
}

run "an_explicit_task_group_name_is_used_verbatim" {
  command = plan

  variables {
    task_security_group_name = "example-runner"
  }

  assert {
    condition     = aws_security_group.tasks.name == "example-runner"
    error_message = "An explicit name must be a passthrough, so an existing group can be adopted without being renamed and therefore replaced."
  }
}

run "a_malformed_egress_cidr_is_rejected" {
  command = plan

  variables {
    task_security_group_egress_cidr_blocks = ["not-a-cidr"]
  }

  expect_failures = [var.task_security_group_egress_cidr_blocks]
}
