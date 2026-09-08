terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.0 floor, not the repository's usual 5.100: locals.tf reads
      # `data.aws_region.current.region`, which does not exist before 6.0. Every other spelling of
      # that attribute is deprecated on current 6.x and warns on every plan. A caller still on 5.x
      # has to move to a 6.x provider to take this module.
      version = ">= 6.0, < 7.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}
