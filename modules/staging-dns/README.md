# terraform-aws-staging-dns

Creates a Route 53 hosted zone in the calling account and delegates it from a parent zone that
lives in another account, by writing the NS record through a second provider configuration. It is
the "staging.<domain> is a child zone of <domain>" pattern every WebbPulse application repeats:
production serves the apex from a zone owned elsewhere, staging gets its own zone and a single NS
record in the parent, and nothing else about DNS differs between the two.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-dns`.
[WebbPulse-Platform](https://github.com/WebbPulse/WebbPulse-Platform) owns this repository,
publishes it to the private registry, and pushes the parent zone id and the Route 53 write role
ARN to each staging workspace.

## How it works

```
parent account                          staging account (the workspace's run role)
  example.com  (hosted zone)              staging.example.com  (aws_route53_zone.this)
    staging.example.com  NS  ──────────►    ns-1.awsdns-..., ns-2..., ns-3..., ns-4...
    (aws_route53_record.delegation,         records for www, api, ACM validation, ...
     written via aws.parent)                (owned by the consumer, zone_id from this module)
```

Two resources, both `count`-gated on `enabled`:

- `aws_route53_zone.this` in the default `aws` provider: `name = zone_name`, the provider's default
  comment ("Managed by Terraform") unless `comment` is set, `force_destroy = false` unless asked,
  tags only from the consumer's `default_tags` unless `tags` is set.
- `aws_route53_record.delegation` in `aws.parent`: an NS record named `zone_name` in
  `parent_zone_id`, TTL `delegation_ttl` (300), pointing at the new zone's name servers. Created
  only when `delegate` is true.

A Terraform module cannot hold a provider block with `assume_role`, so the module declares
`configuration_aliases = [aws.parent]` and the consumer supplies both configurations:

```hcl
provider "aws" {
  alias  = "parent_dns"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.route53_write_role_arn == null ? [] : [var.route53_write_role_arn]
    content {
      role_arn = assume_role.value
    }
  }
}

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

`aws.parent` must be passed even when `enabled` is false; Terraform requires every declared
alias to be wired. A provider block with no `assume_role` is fine for that.

### Ordering

Anything that needs the new zone to resolve from the public internet, above all
`aws_acm_certificate_validation`, has to wait for the delegation record. `depends_on` cannot
name a module output, so depend on the module itself; it contains nothing but the zone and the
delegation:

```hcl
resource "aws_acm_certificate_validation" "site" {
  # ...
  depends_on = [module.staging_dns]
}
```

Records inside the zone use `module.staging_dns.zone_id` and inherit the dependency on the zone
through that reference.

### Modes

| `enabled` | `delegate` | Result |
| --- | --- | --- |
| `true` | `true` (default) | Child zone plus NS delegation in `parent_zone_id`. The staging case. |
| `true` | `false` | Zone only. For an apex whose NS records are held by the registrar, or a zone delegated by hand. |
| `false` | any | Nothing. The production case for an application whose apex zone is owned by another workspace. |

`parent_zone_id` is validated to be set when it is needed (`enabled && delegate`) and ignored
otherwise, so a consumer can pass the same workspace variable in every environment.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `enabled` | Create the zone (and delegation). `false` is a no-op module. | `true` |
| `zone_name` | FQDN of the zone to create, no trailing dot, e.g. `staging.example.com` | required |
| `delegate` | Write the NS record into the parent | `true` |
| `parent_zone_id` | Hosted zone id of the parent, in the account `aws.parent` authenticates to. Required when `enabled && delegate`. | `null` |
| `delegation_ttl` | TTL of the NS record, seconds | `300` |
| `comment` | Zone comment. `null` gives the provider default "Managed by Terraform". | `null` |
| `force_destroy` | Delete all records when the zone is destroyed | `false` |
| `tags` | Extra zone tags on top of `default_tags`. Empty is passed as `null`. | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `zone_id` | Hosted zone id, `null` when disabled |
| `zone_arn` | Hosted zone ARN, `null` when disabled |
| `zone_name` | Zone name as stored, `null` when disabled |
| `name_servers` | The zone's name servers, `null` when disabled |
| `delegation_record_fqdn` | FQDN of the NS record in the parent, `null` when not delegated |
| `delegation_record_id` | Id of the NS record (`<parent_zone_id>_<zone_name>_NS`), `null` when not delegated |

## Adoption

Both application repositories already have the two resources this module creates, with the same
attributes: a zone with only `name` set, and an NS record with `ttl = 300`. Adopting the module is
a state move. The module keeps the provider defaults for every attribute the consumers never set,
so the plan after the `moved` blocks should show `0 to add, 0 to change, 0 to destroy` on staging
and on production. Keep the `providers` map exactly as shown; the zone must stay in the default
provider and only the delegation in the parent-zone provider, otherwise Terraform plans a
replacement.

`moved` blocks are unconditional and apply to whichever workspace's state holds the `from`
address. That is why the CarModPicker recipe below moves the zone in both environments, while the
Portfolio recipe only ever finds a zone in staging.

### CarModPicker

`terraform/route53.tf` today: `aws_route53_zone.carmodpicker[0]` (count `local.custom_domain`,
which is true in production too, because production creates the `carmodpicker.com` zone itself)
and `aws_route53_record.parent_delegation[0]` (count `local.parent_delegation`, staging only,
provider `aws.parent_dns`).

The zone resource exists in production state, so it has to move into the module there as well.
Run the module in "zone only" mode in production and "zone plus delegation" in staging:

```hcl
module "staging_dns" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-dns"
  version = "~> 1.2"

  providers = {
    aws        = aws
    aws.parent = aws.parent_dns
  }

  enabled        = local.custom_domain          # production, or staging with staging_profile "full"
  zone_name      = local.domain_name            # carmodpicker.com / staging.carmodpicker.com
  delegate       = local.parent_delegation      # staging && custom_domain
  parent_zone_id = var.parent_route53_zone_id   # null in production, ignored there
}

moved {
  from = aws_route53_zone.carmodpicker[0]
  to   = module.staging_dns.aws_route53_zone.this[0]
}

moved {
  from = aws_route53_record.parent_delegation[0]
  to   = module.staging_dns.aws_route53_record.delegation[0]
}
```

Then, across `route53.tf`, `acm.tf` and `outputs.tf`:

- delete the two resources and the older `moved { from = aws_route53_zone.carmodpicker ... }`
  block (its move was applied long ago in both workspaces; chaining it into the new block also
  works);
- `aws_route53_zone.carmodpicker[0].zone_id` becomes `module.staging_dns.zone_id`
  (`one(aws_route53_zone.carmodpicker[*].zone_id)` in outputs likewise, the output is already
  `null`-safe);
- `one(aws_route53_zone.carmodpicker[*].name_servers)` becomes `module.staging_dns.name_servers`;
- `depends_on = [aws_route53_record.parent_delegation]` on both
  `aws_acm_certificate_validation` resources becomes `depends_on = [module.staging_dns]`.

`local.parent_delegation` already implies `local.custom_domain`, and the root variable
validations on `parent_route53_zone_id` and `route53_write_role_arn` remain the first line of
defence; the module's own validation repeats the `parent_zone_id` check.

### WebbPulse-Portfolio

`terraform/route53.tf` today: `aws_route53_zone.staging[0]` and
`aws_route53_record.staging_delegation[0]`, both counted on
`var.environment != "production" && local.custom_domains_enabled`, the record through
`aws.parent_dns` into `var.route53_zone_id`. Production never creates a zone, so `enabled` is
simply false there and the module is a no-op:

```hcl
module "staging_dns" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-dns"
  version = "~> 1.2"

  providers = {
    aws        = aws
    aws.parent = aws.parent_dns
  }

  enabled        = var.environment != "production" && local.custom_domains_enabled
  zone_name      = local.domain                 # staging.webbpulse.com
  parent_zone_id = var.route53_zone_id
}

moved {
  from = aws_route53_zone.staging[0]
  to   = module.staging_dns.aws_route53_zone.this[0]
}

moved {
  from = aws_route53_record.staging_delegation[0]
  to   = module.staging_dns.aws_route53_record.delegation[0]
}
```

Then:

- delete the two resources from `route53.tf`;
- in `locals.tf`, `records_zone_id = var.environment == "production" ? var.route53_zone_id : module.staging_dns.zone_id`;
- `depends_on = [aws_route53_record.staging_delegation]` on `aws_acm_certificate_validation.www`
  (`acm.tf`) and `aws_acm_certificate_validation.api` (`apigateway.tf`) becomes
  `depends_on = [module.staging_dns]`;
- in `outputs.tf`, `staging_zone_name_servers` becomes `module.staging_dns.name_servers`.

The workload records (`www`, `apex_a`, `api`, the validation records) keep `provider = aws.dns`;
that provider is the staging account itself in staging and the writer role in production, and it
is unrelated to the delegation.

### Checking the move

Open the pull request against `staging` first and read the speculative plan on the staging
workspace: it should end in `0 to add, 0 to change, 0 to destroy` (or "No changes"), with the two
moved objects reported as `has moved to module.staging_dns...` and nothing marked `~`, `-` or `+`.
A `-/+` on the zone means the provider mapping changed; a `~ comment` or `~ tags` means an
attribute that was left to the provider default is now being set. The production plan runs after
the merge to `main` in the same way.

## Notes

- `terraform validate` run inside `modules/staging-dns` on its own reports "Provider configuration
  not present" for the delegation record. That is Terraform treating the directory as a root
  module without an `aws.parent` configuration; validating any consumer that passes the provider
  (for example `examples/staging-dns-basic` pointed at the local path) succeeds.
- The module does not create the write role in the parent account or the IAM policy that limits
  it to one NS record. WebbPulse-Platform owns that side; the role only needs
  `route53:ChangeResourceRecordSets` and `route53:GetChange` on the parent zone (scoped with
  `route53:ChangeResourceRecordSetsNormalizedRecordNames` and `...RecordTypes` to the child name
  and `NS`), and `route53:ListResourceRecordSets` for refresh.
- DNSSEC: if the parent zone is signed, delegating a child also needs a DS record in the parent
  and signing in the child. Neither is part of this module.
