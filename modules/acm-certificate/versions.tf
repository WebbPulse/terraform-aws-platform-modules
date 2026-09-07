terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"

      # aws         : the account and region the certificate itself lives in. A CloudFront
      #               certificate has to be issued in us-east-1, so that consumer passes a
      #               us-east-1 provider here while the rest of its stack stays regional.
      # aws.records : the account that owns the hosted zone the DNS validation records go into.
      #               Where the zone is in the same account as the certificate, pass the same
      #               provider for both; a module cannot assume roles on its own.
      configuration_aliases = [aws.records]
    }
  }
}
