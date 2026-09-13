# terraform-aws-acm-certificate

A DNS validated ACM certificate, the Route 53 records that prove it, and the validation resource
that waits for issuance. Use it for any certificate a CloudFront distribution or an API Gateway
domain needs.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate`.

## Usage

```hcl
module "site_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws.us_east_1
    aws.records = aws
  }

  domain_name               = "example.com"
  subject_alternative_names = ["*.example.com"]
  zone_id                   = aws_route53_zone.this.zone_id
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `enabled` | Issue the certificate and its validation records; false plans nothing | `true` |
| `domain_name` | Primary domain, the certificate's common name | required |
| `subject_alternative_names` | Extra domains the certificate also covers | `[]` |
| `zone_id` | Zone the validation records are written into; required when `enabled` | `null` |
| `validation_record_ttl` | TTL in seconds on each validation record | `60` |
| `allow_overwrite` | Take over a validation record that already exists in the zone | `true` |
| `tags` | Tags for the certificate, merged over `default_tags` | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `certificate_arn` | ARN from the validation resource, so it is set only once issued; null when disabled |
| `domain_validation_options` | What ACM asked to have proven, one entry per covered domain |
| `validation_record_fqdns` | FQDNs of the validation records this module wrote |

## Gotchas

- Two provider configurations are required. `aws` is where the certificate is issued, which must
  be us-east-1 for a CloudFront certificate and the API's own region for API Gateway.
  `aws.records` is where the DNS validation records are written, possibly a different account.
- Validation records are keyed per covered domain, so a certificate covering `example.com` and
  `*.example.com` gets two keys writing identical record data. That is why `allow_overwrite`
  defaults to `true`.
- When the zone is a delegated child created in the same run, put `depends_on` on the zone module,
  or ACM queries the parent resolvers for a record they have never heard of. `depends_on` cannot
  name an output, so depend on the module itself.
- Every covered domain must validate inside the single `zone_id`; the module cannot spread
  validation records across zones.
- This module is excluded from `terraform validate` in CI because it needs a caller-supplied
  provider alias. Validate it through a consumer or an example that passes `aws.records`.
