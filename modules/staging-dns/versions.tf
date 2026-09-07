terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"

      # aws        : the account that owns the child zone (the run role of the workspace).
      # aws.parent : the account that owns the parent zone, usually a provider block whose
      #              assume_role targets a Route 53 write role there. Both are supplied by the
      #              consumer through the providers meta-argument; a module cannot assume roles
      #              on its own.
      configuration_aliases = [aws.parent]
    }
  }
}
