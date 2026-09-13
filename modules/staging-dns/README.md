# terraform-aws-staging-dns

Creates a Route 53 hosted zone in the calling account and delegates it from a parent zone that may
live in another account, by writing the NS record through a second provider configuration. It is
the "staging.<domain> is a child zone of <domain>" pattern.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-dns`.

## Usage

```hcl
module "staging_dns" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-dns"
  version = "~> 1.2"

  providers = {
    aws        = aws
    aws.parent = aws.parent_dns
  }

  enabled        = var.environment == "staging"
  zone_name      = "staging.example.com"
  parent_zone_id = var.parent_route53_zone_id
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `enabled` | Create the zone and, with `delegate`, the NS delegation; false is a no-op module | `true` |
| `zone_name` | FQDN of the zone to create, no trailing dot, e.g. `staging.example.com` | required |
| `delegate` | Write the NS record for `zone_name` into the parent zone | `true` |
| `parent_zone_id` | Hosted zone id of the parent, required when `enabled && delegate` | `null` |
| `delegation_ttl` | TTL in seconds of the NS delegation record | `300` |
| `comment` | Comment on the hosted zone; null gives the provider's "Managed by Terraform" | `null` |
| `force_destroy` | Delete every record in the zone when the zone is destroyed | `false` |
| `tags` | Extra zone tags on top of `default_tags`; an empty map is passed as null | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `zone_id` | Hosted zone id, null when disabled. Point every record in the zone at this |
| `zone_arn` | Hosted zone ARN, null when disabled |
| `zone_name` | Zone name as stored by Route 53, no trailing dot, null when disabled |
| `name_servers` | Name servers Route 53 assigned to the zone, null when disabled |
| `delegation_record_fqdn` | FQDN of the NS record in the parent, null when not delegated |
| `delegation_record_id` | Id of the NS record (`<parent_zone_id>_<zone_name>_NS`), null when not delegated |

## Gotchas

- The `aws.parent` provider alias must be passed even when `enabled` is false; Terraform requires
  every declared alias to be wired. A provider block with no `assume_role` is fine for that.
- The zone must stay in the default `aws` provider and only the delegation in `aws.parent`.
  Swapping the mapping plans a replacement of the zone.
- Anything that needs the zone to resolve publicly, above all `aws_acm_certificate_validation`,
  has to wait for the delegation record. Use `depends_on = [module.<name>]`, since `depends_on`
  cannot name an output.
- This module is excluded from `terraform validate` in CI because it needs the caller-supplied
  `aws.parent` alias. Validate it through a consumer or an example that passes the provider.
- The parent-account write role and its IAM policy are not created here, and DNSSEC is out of
  scope: a signed parent also needs a DS record and signing in the child.
