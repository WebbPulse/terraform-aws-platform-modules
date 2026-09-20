# terraform-aws-spa-frontend

A single-page application served from a private S3 bucket through CloudFront: the bucket, its public
access block and policy, an origin access control, the distribution, and optionally the Route 53
alias records. Client-side routes work because 403 and 404 from S3 come back as the SPA shell with a
200.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend`.

## Usage

```hcl
module "frontend" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/spa-frontend"
  version = "~> 1.5"

  name = "example-production-frontend"

  aliases             = ["www.example.com", "example.com"]
  acm_certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  create_dns_records = true
  zone_id            = aws_route53_zone.this.zone_id
  dns_records = {
    www  = "www.example.com"
    apex = "example.com"
  }
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | Base name; S3 bucket name and OAC name unless overridden | required |
| `bucket_name` | S3 bucket holding the built site; falls back to `name` | `null` |
| `origin_access_control_name` | OAC name; falls back to `name` | `null` |
| `bucket_policy_sid` | Sid of the CloudFront read statement in the bucket policy | `"AllowCloudFrontServicePrincipal"` |
| `origin_id` | `origin_id` of the S3 origin inside the distribution | `"s3-frontend"` |
| `aliases` | Alternate domain names; the first is canonical and drives `frontend_url` | `[]` |
| `acm_certificate_arn` | Validated us-east-1 certificate covering every alias | `null` |
| `minimum_protocol_version` | Viewer TLS floor when a custom certificate is in use | `"TLSv1.2_2021"` |
| `price_class` | CloudFront price class | `"PriceClass_100"` |
| `default_root_object` | Root object and SPA shell path | `"index.html"` |
| `ipv6_enabled` | Whether the distribution answers over IPv6 | `true` |
| `comment` | Comment shown in the CloudFront console | `null` |
| `cache_mode` | `policies` or `forwarded_values` for the S3 behaviors | `"policies"` |
| `index_cache_mode` | Cache model for the SPA shell behavior alone; null follows `cache_mode` | `null` |
| `index_cache_policies` | Policy ids for the SPA shell behavior; null reuses the default behavior's | `null` |
| `cache_policy_id` | Cache policy in `policies` mode; the managed CachingOptimized policy | `"658327ea-f89d-4fab-a63d-7e88639e58f6"` |
| `origin_request_policy_id` | Origin request policy in `policies` mode | `null` |
| `response_headers_policy_id` | Response headers policy in `policies` mode | `null` |
| `forwarded_values` | Legacy cache settings used only in `forwarded_values` mode | `{}` |
| `spa_fallback_error_codes` | Origin error codes turned into a 200 carrying the SPA shell | `[403, 404]` |
| `error_caching_min_ttl` | Seconds the fallback response is cached | `0` |
| `viewer_request_function_arn` | Existing CloudFront Function for the default behavior | `null` |
| `viewer_request_function` | Build the viewer-request function here from a `canonical_host`; see Gotchas | `null` |
| `access_gate` | staging-access-gate outputs; wires the gate into this distribution | `null` |
| `access_gate_origin_verify_header_value` | The gate's origin verification header value, sensitive | `null` |
| `create_dns_records` | Create alias records for `dns_records` in `zone_id` | `false` |
| `zone_id` | Route 53 hosted zone receiving the alias records | `null` |
| `dns_records` | `{ label = hostname }`; every hostname must also be in `aliases` | `{}` |
| `create_aaaa_records` | Also create AAAA alias records | `false` |
| `tags` | Tags on the bucket and the distribution | `{}` |
| `distribution_tags` | Extra tags for the distribution only, merged over `tags` | `{}` |

`forwarded_values` and `access_gate` object shapes:

```hcl
forwarded_values = {
  query_string    = optional(bool, false)
  cookies_forward = optional(string, "none")
  headers         = optional(list(string))
  min_ttl         = optional(number, 0)
  default_ttl     = optional(number, 86400)
  max_ttl         = optional(number, 31536000)
}

access_gate = {
  key_group_id                                           = string
  viewer_request_function_arn                            = string
  login_origin_domain_name                               = string
  login_origin_access_control_id                         = string
  auth_path_pattern                                      = string
  cache_policy_id_caching_disabled                       = string
  origin_request_policy_id_all_viewer_except_host_header = string
  login_origin_id                                        = optional(string, "access-gate-login")

  api_origin_domain_name    = optional(string)
  api_path_pattern          = optional(string)
  origin_verify_header_name = optional(string)
  api_origin_id             = optional(string, "api")
}
```

## Outputs

| Name | Description |
| --- | --- |
| `bucket_name` | Bucket the deploy pipeline syncs into |
| `bucket_arn` | Bucket ARN, for deploy role IAM policies |
| `bucket_regional_domain_name` | Regional bucket domain name, as used for the S3 origin |
| `distribution_id` | Distribution id, for cache invalidations |
| `distribution_arn` | Distribution ARN, for deploy role IAM policies |
| `distribution_domain_name` | The distribution's own hostname |
| `distribution_hosted_zone_id` | Hosted zone id for alias records pointing at the distribution |
| `origin_access_control_id` | Id of the origin access control |
| `origin_id` | `origin_id` of the S3 origin |
| `frontend_url` | `https://` plus the first alias, or the CloudFront hostname |

### Outputs added with `viewer_request_function`

| Name | Description |
| --- | --- |
| `viewer_request_function_arn` | ARN of the viewer-request function in force on the default behavior |
| `viewer_request_handler_js` | Rendered `appHandler` JavaScript, for a gate's `viewer_request_handler_js` |

## Gotchas

- SPA `index.html` must not be cached like the hashed bundles; verify a cache-control flip from the
  CloudFront access log, not from the bundle name. This module does not write objects, so the
  header comes from the deploy pipeline's sync.
- `access_gate` is the module's biggest footgun: one object silently adds the login origin, the auth
  ordered behavior, an unsigned SPA shell behavior, `trusted_key_groups` on the default behavior and
  the gate's viewer-request function on every behavior.
- `api_origin_domain_name`, `api_path_pattern` and `origin_verify_header_name` go together. Set all
  three for proxy mode or none of them, otherwise the plan fails validation.
- `access_gate_origin_verify_header_value` is a top-level sensitive input, not a member of
  `access_gate`, because one sensitive member would mark the whole object and make the distribution
  plan a spurious in-place update.
- With `access_gate` set, `viewer_request_function_arn` is ignored: the gate's function takes the
  slot and must wrap the consumer's handler.
- `acm_certificate_arn` must be in us-east-1 and is required whenever `aliases` is non-empty.
  CloudFront accepts certificates from no other region.
- Do not feed `distribution_arn` back into the gate's `cloudfront_distribution_arn` in the same
  stack; that is a dependency cycle.
- Alias records use this module's own `aws` provider. When the zone lives in another account, leave
  `create_dns_records` false and point records at `distribution_domain_name` and
  `distribution_hosted_zone_id`.
- Every hostname in `dns_records` must also appear in `aliases`, otherwise CloudFront answers it
  with a 403. `dns_records` is keyed by label, not hostname, so addresses stay stable across
  environments.
- `ipv6_enabled` alone does not create AAAA records; `create_aaaa_records` must also be true.
- A live distribution that mixes the two cache models, `forwarded_values` on the default behavior and
  a policy-driven SPA shell behavior, plans an update on that one behavior until `index_cache_mode`
  and `index_cache_policies` match what the console shows.
- **`viewer_request_function` builds the function here instead of taking one by ARN.** It renders
  the same two templates every product had copied into its own `cloudfront_functions/` directory:
  a canonical host 301 redirect followed by the SPA URI rewrite. `canonical_host = "apex"`
  redirects `www.<domain>` to `<domain>`, `"www"` redirects the other way, and `"none"` writes no
  redirect at all and leaves only the rewrite. `domain` is the registrable domain with no `www.`
  prefix either way; the module refuses one, because `canonical_host` is what picks the side.
- `viewer_request_function` and `viewer_request_function_arn` are mutually exclusive and the module
  refuses both, as a `precondition` on the function. Leaving `viewer_request_function` null keeps
  the existing input working exactly as before, and an existing consumer's plan is empty.
- With `access_gate` set, the module still renders `viewer_request_handler_js` but builds no
  function of its own: the gate's function wraps the handler and takes the viewer-request slot.
  Pass the output into the gate's `viewer_request_handler_js` and the two stay in step.
- **A product adopting `viewer_request_function` from its own copy will see a one line function code
  diff, not an empty plan.** The redirect and rewrite logic is byte-identical to what CarModPicker
  and Standupless deploy today, but the comments in the shared template are worded once for both
  directions rather than per product, and `code` is a tracked attribute of
  `aws_cloudfront_function`. The apply republishes the function with identical behaviour. Adopt it
  in its own commit so that diff is readable, and add:

  ```hcl
  moved {
    from = aws_cloudfront_function.frontend_uri_rewrite
    to   = module.frontend.aws_cloudfront_function.viewer_request[0]
  }
  ```

  The `[0]` is the module's `count`. Delete the product's `cloudfront_function.tf` and its
  `cloudfront_functions/` directory in the same commit. The function's `name` defaults to
  `<name>-uri-rewrite`, which for a module named `<prefix>-frontend` is the
  `<prefix>-frontend-uri-rewrite` both products already use; `name` is immutable on a CloudFront
  Function, so a product whose existing function is called something else passes
  `viewer_request_function.name` or the `moved` block turns into a replacement.
