# terraform-aws-spa-frontend

A single-page application served from a private S3 bucket through CloudFront: the bucket, its
public access block and policy, an origin access control, the distribution, and optionally the
Route 53 alias records. Client-side routes work because 403 and 404 from S3 come back as the SPA
shell with a 200. A staging-access-gate instance can be attached with one object argument and the
module does all the distribution wiring the gate's consumer checklist asks for.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend`.
[WebbPulse-Platform](https://github.com/WebbPulse/WebbPulse-Platform) owns this repository and
publishes it to the private registry.

## How it works

```
browser ── https://www.<domain>/anything
             │
             ▼
     aws_cloudfront_distribution.this
       ├─ viewer-request function (consumer's, or the access gate's)
       ├─ default behavior ──► S3 origin (aws_s3_bucket.this via aws_cloudfront_origin_access_control.this)
       │     403 / 404 from S3 ──► 200 /index.html
       └─ with access_gate set:
            /_auth/*     ──► login Lambda function URL origin
            /api/*       ──► API host origin + origin verification header, signed cookies required
            /index.html  ──► S3 origin without the key group, so the error fallback can fetch it
```

The module was written so that the two hand-written frontends in CarModPicker and
WebbPulse-Portfolio can be moved into it with `moved` blocks and a plan of zero adds, zero
changes, zero destroys. Every attribute the two differ on is an input, and the resource addresses
are the plain `this` form.

## Design decisions

**Certificate stays with the consumer.** `acm_certificate_arn` takes a validated us-east-1
certificate ARN, or null when there are no aliases. The module does not create certificates
because doing so needs a second provider configuration (us-east-1) passed through
`configuration_aliases`, which every consumer would then have to wire even when it has no custom
domain, and because the DNS validation records land in different places per consumer:
CarModPicker writes them into its own zone, Portfolio production writes them through a
cross-account `aws.dns` provider. Keeping certificate plus validation in the consumer costs about
forty lines there and keeps this module single-provider. Revisit when the composite root module
exists and can own the us-east-1 provider for everyone.

**DNS records use this module's provider, and are optional.** `create_dns_records`, `zone_id`
and `dns_records` add A (and optionally AAAA) alias records in the same account as the bucket and
distribution. A module has one `aws` provider; passing `providers = { aws = aws.dns }` would move
the bucket and distribution into the DNS account too. So a consumer whose records live in a zone
another account owns keeps those records outside the module and points them at
`distribution_domain_name` / `distribution_hosted_zone_id`. That is Portfolio production
(records go into the webbpulse.com zone in the management account). CarModPicker owns its zone in
each environment and can hand the records to the module. `dns_records` is keyed by a label
(`www`, `apex`) rather than by hostname so the resource addresses are the same in staging and
production, which is what makes a single set of `moved` blocks work for both workspaces.

**The viewer-request function is an input, not a resource.** Each application has its own code
(CarModPicker rewrites extensionless paths, Portfolio only redirects the apex), and when the
staging access gate is on, the gate's function wraps that code and must take the slot. So the
module takes `viewer_request_function_arn` and, when `access_gate` is set, uses the gate's ARN
instead and ignores the consumer's.

**`cache_mode` reproduces both cache models.** `policies` (default) uses managed cache, origin
request and response headers policies. `forwarded_values` uses the legacy block with explicit
TTLs. Both are kept because switching a live distribution from one to the other, while only an
in-place update, changes caching behavior and is a decision for the application, not for the
module release.

A live distribution can also mix them. WebbPulse-Portfolio's default behavior kept its legacy
`forwarded_values` block while the `/index.html` behavior, added later with the access gate, was
written with a managed cache policy. `index_cache_mode` and `index_cache_policies` let the SPA
shell behavior pick its own model and its own policies; both default to whatever the default
behavior uses, so a consumer that sets neither plans exactly what it planned before they existed.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | Base name; bucket name and OAC name unless overridden | required |
| `bucket_name` | S3 bucket name | `name` |
| `origin_access_control_name` | OAC name | `name` |
| `bucket_policy_sid` | Sid of the CloudFront read statement in the bucket policy | `AllowCloudFrontServicePrincipal` |
| `origin_id` | origin_id of the S3 origin | `s3-frontend` |
| `aliases` | Alternate domain names; first is canonical | `[]` |
| `acm_certificate_arn` | Validated us-east-1 certificate, required with aliases | `null` |
| `minimum_protocol_version` | Viewer TLS floor with a custom certificate | `TLSv1.2_2021` |
| `price_class` | `PriceClass_100`, `PriceClass_200` or `PriceClass_All` | `PriceClass_100` |
| `default_root_object` | Root object and SPA shell | `index.html` |
| `ipv6_enabled` | `is_ipv6_enabled` on the distribution | `true` |
| `comment` | Distribution comment | `null` |
| `cache_mode` | `policies` or `forwarded_values` | `policies` |
| `index_cache_mode` | Cache model for the SPA shell behavior alone; null follows `cache_mode` | `null` |
| `index_cache_policies` | `{ cache_policy_id, origin_request_policy_id, response_headers_policy_id }` for the SPA shell behavior; null reuses the default behavior's three | `null` |
| `cache_policy_id` | Cache policy in `policies` mode | CachingOptimized `658327ea-f89d-4fab-a63d-7e88639e58f6` |
| `origin_request_policy_id` | Origin request policy in `policies` mode | `null` |
| `response_headers_policy_id` | Response headers policy in `policies` mode | `null` |
| `forwarded_values` | `{ query_string, cookies_forward, headers, min_ttl, default_ttl, max_ttl }` in `forwarded_values` mode | `false`, `none`, unset, `0`, `86400`, `31536000` |
| `spa_fallback_error_codes` | Error codes turned into the SPA shell | `[403, 404]` |
| `error_caching_min_ttl` | Seconds the fallback is cached | `0` |
| `viewer_request_function_arn` | CloudFront Function for the default behavior | `null` |
| `access_gate` | staging-access-gate outputs, see below | `null` |
| `access_gate_origin_verify_header_value` | The gate's origin verification header value, sensitive; required with `access_gate` | `null` |
| `create_dns_records` | Create alias records in `zone_id` | `false` |
| `zone_id` | Hosted zone for the records | `null` |
| `dns_records` | `{ label = hostname }`, every hostname also in `aliases` | `{}` |
| `create_aaaa_records` | Also create AAAA records | `false` |
| `tags` | Tags for bucket and distribution | `{}` |
| `distribution_tags` | Extra tags for the distribution only | `{}` |

### `access_gate`

An object with the gate module's outputs of the same names plus the API host:

```hcl
access_gate = var.staging_access_gate ? {
  key_group_id                                           = module.gate[0].key_group_id
  viewer_request_function_arn                            = module.gate[0].viewer_request_function_arn
  login_origin_domain_name                               = module.gate[0].login_origin_domain_name
  login_origin_access_control_id                         = module.gate[0].login_origin_access_control_id
  auth_path_pattern                                      = module.gate[0].auth_path_pattern
  api_origin_domain_name                                 = "api.staging.example.com"
  api_path_pattern                                       = module.gate[0].api_path_pattern
  origin_verify_header_name                              = module.gate[0].origin_verify_header_name
  cache_policy_id_caching_disabled                       = module.gate[0].cache_policy_id_caching_disabled
  origin_request_policy_id_all_viewer_except_host_header = module.gate[0].origin_request_policy_id_all_viewer_except_host_header
} : null

access_gate_origin_verify_header_value = one(module.gate[*].origin_verify_header_value)
```

Optional keys `login_origin_id` (`access-gate-login`) and `api_origin_id` (`api`) name the two
extra origins. When set, the module adds exactly what the gate README's consumer checklist lists:
both origins, `trusted_key_groups` on the default and API behaviors, ordered behaviors for the
auth pattern, the API pattern and `/<default_root_object>` (the last one without the key group),
and the gate function as viewer-request on all four behaviors.

The origin verification header value is deliberately **not** a member of this object. It is the
separate `access_gate_origin_verify_header_value` input, declared `sensitive`. An object with one
sensitive member is sensitive as a whole at the module boundary, so every attribute read out of it
inside the module (path patterns, origin ids, policy ids, TTLs) would carry the mark, and the
distribution would plan an in-place update where only the sensitivity differs. Splitting the secret
out keeps the mark on the one value that needs it and leaves the rest readable in plans. The
`access_gate` object itself is not `sensitive` for the same reason.

Passing `null` for `access_gate` removes all of it again, so a production workspace that passes
`null` plans a no-op. Do not pass the distribution ARN back to the gate's
`cloudfront_distribution_arn`: that is a cycle.

## Outputs

| Name | Description |
| --- | --- |
| `bucket_name` | Bucket the deploy pipeline syncs into |
| `bucket_arn` | For deploy role IAM policies |
| `bucket_regional_domain_name` | The S3 origin domain name |
| `distribution_id` | For cache invalidations |
| `distribution_arn` | For deploy role IAM policies |
| `distribution_domain_name` | For alias records the consumer creates itself |
| `distribution_hosted_zone_id` | Alias record zone id |
| `origin_access_control_id` | OAC id |
| `origin_id` | origin_id of the S3 origin |
| `frontend_url` | `https://` plus the first alias, or the CloudFront hostname |

## Adoption

Both applications can move their frontend into this module with the `moved` blocks below and a
plan that reads `Plan: 0 to add, 0 to change, 0 to destroy` (only "has moved to" lines). The
module inherits the root `aws` provider, so `default_tags` and `ignore_tags` carry over. Merge to
`staging` first and read the speculative plan on the staging workspace before touching `main`.

Provider defaults that both estates already carry and that the module leaves untouched: OAC
description `Managed by Terraform`, `http_version = http2`, no `comment`, no `web_acl_id`, no
logging, `connection_attempts = 3`, `connection_timeout = 10`.

### CarModPicker

Today: `terraform/s3.tf` (frontend bucket section), `cloudfront.tf`, `route53.tf` (`apex_a`,
`www`). The certificate (`acm.tf`), the hosted zone, the parent NS delegation and the CloudFront
Function (`cloudfront_function.tf`) stay where they are.

```hcl
module "frontend" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend"
  version = "~> 1.4"

  name                       = "${local.prefix}-frontend"     # bucket carmodpicker-<env>-frontend
  origin_access_control_name = "${local.prefix}-frontend-oac"
  origin_id                  = "${local.prefix}-frontend-s3"
  bucket_policy_sid          = "AllowCloudFrontOAC"

  aliases             = local.custom_domain ? ["www.${local.domain_name}", local.domain_name] : []
  acm_certificate_arn = one(aws_acm_certificate_validation.carmodpicker[*].certificate_arn)

  viewer_request_function_arn = aws_cloudfront_function.frontend_uri_rewrite.arn

  # cache_mode = "policies" and cache_policy_id = CachingOptimized are the defaults.
  origin_request_policy_id   = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # CORS-S3Origin
  response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03" # SecurityHeadersPolicy
  # error_caching_min_ttl = 0 is the default.

  distribution_tags = { Name = "${local.prefix}-frontend" }

  create_dns_records = local.custom_domain
  zone_id            = one(aws_route53_zone.carmodpicker[*].zone_id)
  dns_records = {
    www  = "www.${local.domain_name}"
    apex = local.domain_name
  }
}

moved {
  from = aws_s3_bucket.frontend
  to   = module.frontend.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_public_access_block.frontend
  to   = module.frontend.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_policy.frontend
  to   = module.frontend.aws_s3_bucket_policy.this
}

moved {
  from = aws_cloudfront_origin_access_control.frontend
  to   = module.frontend.aws_cloudfront_origin_access_control.this
}

moved {
  from = aws_cloudfront_distribution.frontend
  to   = module.frontend.aws_cloudfront_distribution.this
}

moved {
  from = aws_route53_record.apex_a[0]
  to   = module.frontend.aws_route53_record.alias_a["apex"]
}

moved {
  from = aws_route53_record.www[0]
  to   = module.frontend.aws_route53_record.alias_a["www"]
}
```

Keep the existing `moved` blocks `aws_route53_record.apex_a -> aws_route53_record.apex_a[0]` and
`aws_route53_record.www -> aws_route53_record.www[0]`; Terraform follows the chain. Delete the five
resources and the two records they replace, plus `local.frontend_origin_id`, and repoint:

- `iam_github_actions.tf`: `aws_s3_bucket.frontend.arn` -> `module.frontend.bucket_arn`,
  `aws_cloudfront_distribution.frontend.arn` -> `module.frontend.distribution_arn`.
- `outputs.tf`: `cloudfront_domain` -> `module.frontend.distribution_domain_name`,
  `cloudfront_distribution_id` -> `module.frontend.distribution_id`,
  `frontend_bucket` -> `module.frontend.bucket_name`.
- `locals.tf`: `frontend_url = module.frontend.frontend_url` (same value as today).

With the staging access gate on, pass the `access_gate` object shown above with
`api_origin_domain_name = "api.${local.domain_name}"`, pass
`access_gate_origin_verify_header_value = one(module.staging_access_gate[*].origin_verify_header_value)`,
and give the gate `viewer_request_handler_js` built from
`cloudfront_functions/uri_rewrite.js.tftpl` with `handler` renamed to `appHandler`. CarModPicker
runs `cache_mode = "policies"` on every behavior, so it leaves `index_cache_mode` and
`index_cache_policies` unset.

### WebbPulse-Portfolio

Today: `terraform/frontend.tf`. The certificate (`acm.tf`), the CloudFront Function
`apex_redirect`, and the Route 53 records (`route53.tf`) stay where they are. The records stay
because production writes them through `aws.dns` into the management account's zone; the module
cannot do that with the provider that owns the bucket. Point them at the module's outputs instead.

```hcl
module "frontend" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend"
  version = "~> 1.4"

  name = "${local.prefix}-frontend" # bucket and OAC webbpulse-<env>-frontend
  # origin_id = "s3-frontend" and bucket_policy_sid = "AllowCloudFrontServicePrincipal" are the defaults.

  aliases             = local.custom_domains_enabled ? [local.www_host, local.domain] : []
  acm_certificate_arn = one(aws_acm_certificate_validation.www[*].certificate_arn)

  viewer_request_function_arn = one(aws_cloudfront_function.apex_redirect[*].arn)

  cache_mode = "forwarded_values"
  # forwarded_values defaults: query_string false, cookies none, TTLs 0 / 86400 / 31536000.
  error_caching_min_ttl = 10

  # The live distribution mixes the two cache models: the default behavior kept its legacy
  # forwarded_values block, while the /index.html behavior was added later with the managed
  # CachingOptimized policy and nothing else. These two inputs reproduce that exactly.
  index_cache_mode     = "policies"
  index_cache_policies = { cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" }

  create_dns_records = false
}

moved {
  from = aws_s3_bucket.frontend
  to   = module.frontend.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_public_access_block.frontend
  to   = module.frontend.aws_s3_bucket_public_access_block.this
}

moved {
  from = aws_s3_bucket_policy.frontend
  to   = module.frontend.aws_s3_bucket_policy.this
}

moved {
  from = aws_cloudfront_origin_access_control.frontend
  to   = module.frontend.aws_cloudfront_origin_access_control.this
}

moved {
  from = aws_cloudfront_distribution.frontend
  to   = module.frontend.aws_cloudfront_distribution.this
}
```

Repoint:

- `route53.tf` `www` and `apex_a`: `alias.name = module.frontend.distribution_domain_name`,
  `alias.zone_id = module.frontend.distribution_hosted_zone_id`.
- `iam_github_actions.tf`: `aws_s3_bucket.frontend.arn` -> `module.frontend.bucket_arn`,
  `aws_cloudfront_distribution.frontend.arn` -> `module.frontend.distribution_arn`.
- `outputs.tf`: `cloudfront_distribution_id` -> `module.frontend.distribution_id`,
  `frontend_bucket` -> `module.frontend.bucket_name`.
- `locals.tf`: `frontend_url = module.frontend.frontend_url`.

With the staging access gate on, pass the `access_gate` object with
`api_origin_domain_name = local.api_host`, pass
`access_gate_origin_verify_header_value = one(module.staging_access_gate[*].origin_verify_header_value)`,
and hand the apex redirect code to the gate as `viewer_request_handler_js` (rename `handler` to
`appHandler`); `aws_cloudfront_function.apex_redirect` can then be gated off in staging, since the
module ignores `viewer_request_function_arn` while the gate is attached. Keep
`index_cache_mode = "policies"` and the one-key `index_cache_policies` above: the SPA shell
behavior only exists while the gate is on, and those two inputs are what make it match.

### What could still show a diff

- The bucket policies are compared semantically by the provider, but the module also matches
  the Sid so the JSON is byte-identical.
- `min_ttl`, `default_ttl`, `max_ttl` are sent as null in `policies` mode. The provider stores
  0 / computed values for them on a policy-driven distribution and treats null as unset, so no
  change is planned. If a plan ever shows them, set `cache_mode = "forwarded_values"` only if the
  live distribution really has a forwarded_values block; otherwise report it as a module bug.
- `trusted_key_groups` is computed and left null without a gate; adding a gate later sets it.
- The SPA shell behavior inherits `cache_mode` and the default behavior's three policy ids unless
  `index_cache_mode` and `index_cache_policies` are set. A live distribution that mixes the two
  models plans an update on that one behavior until they are; set them to whatever the console
  shows for `/index.html`.

## Examples

- `examples/spa-frontend-basic`: production-shaped site with a consumer-owned certificate, an apex
  redirect function and module-managed alias records.
- `examples/spa-frontend-with-access-gate`: staging site behind the staging-access-gate module,
  with `access_gate` toggled by a variable so the same code plans a plain site when it is false.
