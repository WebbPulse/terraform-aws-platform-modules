# terraform-aws-acm-certificate

A DNS validated ACM certificate together with the Route 53 records that prove it and the
validation resource that waits for issuance. Both application estates ran three copies of this
between them, so a change to the pattern had to be made three times; this is that shape lifted
into one place.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate`.

## What it creates

```
aws_acm_certificate.this[0]                  DNS validated, create_before_destroy
aws_route53_record.validation["<domain>"]    one per covered domain, CNAME, your TTL
aws_acm_certificate_validation.this[0]       waits for ACM to issue, exports the usable ARN
```

With `enabled = false` the module plans nothing at all, for an environment that serves no custom
domain.

## Two providers, and why

The module declares two provider configurations:

- `aws` decides where the certificate is issued. A CloudFront certificate has to be issued in
  us-east-1 and nowhere else, so a consumer passes a us-east-1 provider here while the rest of its
  stack stays regional. An API Gateway certificate has to be issued in the API's own region.
- `aws.records` decides where the DNS validation records are written.

Those are not always the same account. WebbPulse-Portfolio in production owns its zone in the
management account and writes into it through a provider that assumes a Route 53 write role, while
its certificates are issued in the workload account. CarModPicker owns its zone in the same account
as its certificates and passes the same provider for both:

```hcl
providers = {
  aws         = aws.us_east_1
  aws.records = aws
}
```

Splitting the two is the reason this module exists at all. The `http-api` module's README records
the earlier decision to leave certificates with the consumer precisely because a module has one
`aws` provider; a second configuration alias removes that objection.

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

Pass `module.site_certificate.certificate_arn` to CloudFront or to an API Gateway domain. It comes
from the validation resource, not from the certificate, so the consumer waits for ACM to issue
before anything tries to serve traffic with it.

`examples/acm-certificate-basic` is the single-account pair of certificates a typical stack needs.
`examples/acm-certificate-cross-account-dns` is the Portfolio shape, records written through an
assumed role.

## One record per covered domain

`for_each` is keyed by the domain name each validation record belongs to, taken straight from the
certificate's `domain_validation_options`. A certificate covering `example.com` and
`*.example.com` gets two keys even though ACM proves both with a single CNAME: the two entries
carry identical record data, and both write the same record. That is why `allow_overwrite`
defaults to `true`, and it is also why the key set matches what both applications already have in
state, so adoption is a pure state move.

## Ordering against a delegated zone

Where the zone is a delegated child created in the same run, the certificate must not be validated
until the delegation is live in the parent, or ACM asks the parent's resolvers for a record they
have never heard of. `depends_on` cannot name an output, so depend on the module that creates the
zone. Both applications already do this, and the dependency moves onto the module block:

```hcl
depends_on = [module.staging_dns]
```

On the module block this covers every resource inside, which is stricter than the old
`depends_on` on the validation resource alone and never plans a difference.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `enabled` | Issue the certificate and its records; false plans nothing | `true` |
| `domain_name` | Primary domain, the certificate's common name | required |
| `subject_alternative_names` | Extra covered domains | `[]` |
| `zone_id` | Zone the validation records go into, required when enabled | `null` |
| `validation_record_ttl` | TTL on each validation record | `60` |
| `allow_overwrite` | Take over a validation record that already exists | `true` |
| `tags` | Tags for the certificate, merged over `default_tags` | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `certificate_arn` | ARN from the validation resource, so it is only set once issued; null when disabled |
| `domain_validation_options` | What ACM asked to have proven, one entry per covered domain |
| `validation_record_fqdns` | FQDNs of the validation records written |

## Adoption

Both applications hold two certificates each, a us-east-1 one for CloudFront and a regional one
for the API, and both already key their validation records by domain name. The module reproduces
those keys exactly, so every adoption below is a state move with no keyed `moved` block per
record. The plans quoted are speculative runs against each staging workspace.

Both repositories already carry `moved` blocks migrating these resources from unindexed to
`[0]`. Leave them in place; the blocks below chain off them.

### CarModPicker

Zone and certificates are in one account, so the same provider goes to `aws.records`. Replace the
whole of `terraform/acm.tf` with:

```hcl
module "certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws.us_east_1
    aws.records = aws
  }

  enabled     = local.custom_domain
  domain_name = local.domain_name
  subject_alternative_names = [
    "*.${local.domain_name}",
  ]
  zone_id = module.staging_dns.zone_id

  depends_on = [module.staging_dns]
}

module "api_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws
    aws.records = aws
  }

  enabled     = local.custom_domain
  domain_name = "api.${local.domain_name}"
  zone_id     = module.staging_dns.zone_id

  depends_on = [module.staging_dns]
}

moved {
  from = aws_acm_certificate.carmodpicker[0]
  to   = module.certificate.aws_acm_certificate.this[0]
}

moved {
  from = aws_route53_record.acm_validation
  to   = module.certificate.aws_route53_record.validation
}

moved {
  from = aws_acm_certificate_validation.carmodpicker[0]
  to   = module.certificate.aws_acm_certificate_validation.this[0]
}

moved {
  from = aws_acm_certificate.api[0]
  to   = module.api_certificate.aws_acm_certificate.this[0]
}

moved {
  from = aws_route53_record.acm_api_validation
  to   = module.api_certificate.aws_route53_record.validation
}

moved {
  from = aws_acm_certificate_validation.api[0]
  to   = module.api_certificate.aws_acm_certificate_validation.this[0]
}
```

Then the two consumers of the ARNs:

- `cloudfront.tf`: `one(aws_acm_certificate_validation.carmodpicker[*].certificate_arn)` becomes
  `module.certificate.certificate_arn`, which is already null-safe when the custom domain is off.
- `apigateway.tf`: `local.custom_domain ? aws_acm_certificate_validation.api[0].certificate_arn : null`
  becomes `module.api_certificate.certificate_arn`.

`0 to add, 0 to change, 0 to destroy` on CarModPicker-staging, with all seven resources reported
as moved.

### WebbPulse-Portfolio

Same two certificates, but the records go through `aws.dns`, which assumes a role into the
management account in production and writes locally in staging. Replace `terraform/acm.tf` with:

```hcl
module "www_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws.us_east_1
    aws.records = aws.dns
  }

  enabled                   = local.custom_domains_enabled
  domain_name               = local.www_host
  subject_alternative_names = [local.domain]
  zone_id                   = local.records_zone_id

  depends_on = [module.staging_dns]
}

module "api_certificate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/acm-certificate"
  version = "~> 1.6"

  providers = {
    aws         = aws
    aws.records = aws.dns
  }

  enabled     = local.custom_domains_enabled
  domain_name = local.api_host
  zone_id     = local.records_zone_id

  depends_on = [module.staging_dns]
}

moved {
  from = aws_acm_certificate.www[0]
  to   = module.www_certificate.aws_acm_certificate.this[0]
}

moved {
  from = aws_route53_record.www_cert_validation
  to   = module.www_certificate.aws_route53_record.validation
}

moved {
  from = aws_acm_certificate_validation.www[0]
  to   = module.www_certificate.aws_acm_certificate_validation.this[0]
}

moved {
  from = aws_acm_certificate.api[0]
  to   = module.api_certificate.aws_acm_certificate.this[0]
}

moved {
  from = aws_route53_record.api_cert_validation
  to   = module.api_certificate.aws_route53_record.validation
}

moved {
  from = aws_acm_certificate_validation.api[0]
  to   = module.api_certificate.aws_acm_certificate_validation.this[0]
}
```

Then:

- `frontend.tf`: `one(aws_acm_certificate_validation.www[*].certificate_arn)` becomes
  `module.www_certificate.certificate_arn`.
- `apigateway.tf`: `local.custom_domains_enabled ? aws_acm_certificate_validation.api[0].certificate_arn : null`
  becomes `module.api_certificate.certificate_arn`.

`0 to add, 0 to change, 0 to destroy` on WebbPulse-Portfolio-staging, with all seven resources
reported as moved.

### Production

Neither application's production state was planned against here, but the addresses are the same in
both workspaces and the `moved` blocks are unconditional, so the same move applies. Production
differs only in that Portfolio's `records_zone_id` is the parent zone and `aws.dns` assumes the
write role, which the module does not see: it takes the provider it is handed.
