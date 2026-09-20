# terraform-aws-http-api

An API Gateway HTTP API in front of one or many Lambda functions: the API, a `$default` stage with
layered throttling and a JSON access log, one proxy integration and one invoke permission per
backend, the routes, and optionally a custom domain, API mapping, Route 53 alias and a JWT
authorizer.

The default access log line carries request, response and integration fields, plus `authorizerError`,
`errorMessage` and `errorType` so an authorizer or gateway rejection explains itself.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api`.

## Usage

```hcl
module "api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api"
  version = "~> 2.0"

  name = "example-production-api"

  integrations = {
    legacy = {
      lambda_function_name = aws_lambda_function.api.function_name
      lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
    }
  }

  default_integration = "legacy"

  domain_name     = "api.example.com"
  certificate_arn = aws_acm_certificate_validation.api.certificate_arn
  zone_id         = aws_route53_zone.this.zone_id
}
```

## Admitting agent API keys

Products issue agent keys with their own prefix, for example `wpk_`, and verify them in process.
Those bearers are not JWTs, so the native authorizer 401s them at the gateway. Switch the marked
routes to this module's Lambda authorizer to let them through:

```hcl
identity_jwt = {
  issuer   = "https://api.example.com/api/auth"
  audience = "example-production-api"

  mode             = "lambda"
  api_key_prefixes = ["wpk_"]
}
```

Nothing else changes. The routes already marked `require_identity_jwt` keep their marking, the
authorizer invoke permission is created by this module, and the backend sees the same
`authorizer.jwt.claims` for a token as it did under native mode. A bearer starting with a listed
prefix arrives with no claims, which is the backend's signal to verify the key itself.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | API name, and the default access log group name `/aws/apigateway/<name>` | required |
| `integrations` | Lambda backends keyed by a short stable name, one integration and one invoke permission each | required |
| `description` | API description shown in the console, null for none | `null` |
| `default_integration` | Which `integrations` key serves `$default`; null creates no `$default` route | `"legacy"` |
| `routes` | Explicit routes keyed by route key, each naming an integration and its authorization | `{}` |
| `payload_format_version` | Default proxy payload format for integrations that set none, `1.0` or `2.0` | `"2.0"` |
| `throttling_burst_limit` | Stage default route burst limit | `50` |
| `throttling_rate_limit` | Stage default route requests per second | `25` |
| `route_settings` | Per-route stage overrides keyed by route key or `"$default"` | `{}` |
| `detailed_metrics_enabled` | Per-route CloudWatch metrics for the whole stage | `false` |
| `access_log_group_name` | Access log group name, null for `/aws/apigateway/<name>` | `null` |
| `access_log_retention_days` | Access log retention in days, 0 keeps logs forever | `14` |
| `access_log_format` | Field name to `$context` variable, stored as `jsonencode()` with sorted keys | 17 fields, see `variables.tf` |
| `lambda_permission_statement_id` | Base `statement_id` of the invoke permissions | `"AllowHttpApiInvoke"` |
| `disable_execute_api_endpoint` | Turn off the execute-api hostname; requires `domain_name` | `false` |
| `authorizer_id` | Authorizer applied to every route as `CUSTOM`, null makes every route `NONE` | `null` |
| `cors_configuration` | API-level CORS object, null creates no `cors_configuration` block | `null` |
| `domain_name` | Custom hostname, null creates no domain, mapping or DNS record | `null` |
| `certificate_arn` | Issued ACM certificate in this region, required with `domain_name` | `null` |
| `zone_id` | Route 53 zone for the alias record, same account as the API | `null` |
| `dns_record_enabled` | Plan time known override for whether the alias record is written; null derives it from `zone_id` | `null` |
| `domain_name_tags` | Extra tags on the custom domain only, merged over `tags` | `{}` |
| `tags` | Tags on the API, stage, log group and custom domain | `{}` |
| `identity_jwt` | Turns on gateway enforcement of the identity module's access tokens, `mode` picking the native or the Lambda authorizer | `null` |
| `identity_jwt_depends_on` | What must already answer before the JWT authorizer is created | `[]` |

Object shapes:

```hcl
integrations = map(object({
  lambda_function_name           = string
  lambda_invoke_arn              = string # the invoke_arn, not the plain arn
  payload_format_version         = optional(string)
  timeout_milliseconds           = optional(number) # 50 to 30000
  lambda_permission_statement_id = optional(string)
}))

routes = map(object({
  integration          = string
  authorization_type   = optional(string) # NONE, CUSTOM, AWS_IAM or JWT
  authorizer_id        = optional(string)
  authorization_scopes = optional(list(string))
  require_identity_jwt = optional(bool, false)
}))

route_settings = map(object({
  throttling_burst_limit   = optional(number)
  throttling_rate_limit    = optional(number)
  detailed_metrics_enabled = optional(bool)
}))

cors_configuration = object({
  allow_credentials = optional(bool)
  allow_headers     = optional(list(string))
  allow_methods     = optional(list(string))
  allow_origins     = optional(list(string))
  expose_headers    = optional(list(string))
  max_age           = optional(number)
})

identity_jwt = object({
  issuer           = string # https, no trailing slash, already serving discovery
  audience         = string
  name             = optional(string) # defaults to "<name>-identity-jwt"
  audiences        = optional(list(string))
  identity_sources = optional(list(string)) # defaults to ["$request.header.Authorization"]
  authorizer_id    = optional(string)       # attach an existing authorizer instead of creating one

  # "native" is API Gateway's own JWT authorizer, "lambda" is this module's
  # REQUEST authorizer. Only "lambda" can admit an API key bearer.
  mode = optional(string, "native")

  # lambda mode only
  api_key_prefixes          = optional(list(string), [])
  result_ttl_seconds        = optional(number, 300)
  jwks_url                  = optional(string) # defaults to "<issuer>/.well-known/jwks.json"
  jwks_ttl_seconds          = optional(number, 300)
  jwks_fetch_timeout_ms     = optional(number, 4000)
  clock_skew_seconds        = optional(number, 60)
  lambda_function_name      = optional(string) # defaults to "<name>-identity-authorizer"
  lambda_log_retention_days = optional(number, 14)
})
```

## Outputs

| Name | Description |
| --- | --- |
| `api_id` | API id; give it to staging-access-gate as `http_api_id` |
| `api_arn` | API ARN |
| `execution_arn` | Execution ARN, the prefix of every route's invoke ARN |
| `api_endpoint` | The execute-api endpoint, which answers 403 once disabled |
| `stage_id` | `$default` stage id |
| `stage_arn` | `$default` stage ARN |
| `integration_ids` | Integration ids keyed by `integrations` key |
| `default_integration_id` | Id of the integration behind `$default`, null when there is none |
| `route_ids` | Route ids keyed by route key, `$default` included |
| `route_integrations` | Which integration serves each route key |
| `lambda_permission_statement_ids` | `statement_id` of each invoke permission, keyed by `integrations` key |
| `access_log_group_name` | Access log group name |
| `access_log_group_arn` | Access log group ARN |
| `domain_name` | The custom hostname, null when none was configured |
| `custom_domain_target_domain_name` | Regional hostname to alias to, null when no custom domain |
| `custom_domain_hosted_zone_id` | Hosted zone id of that hostname, null when no custom domain |
| `api_url` | `https://<domain_name>`, or the execute-api endpoint without a domain |
| `identity_jwt_authorizer_id` | Id of the identity authorizer in either mode, null when `identity_jwt` is unset |
| `identity_jwt_authorizer_name` | Name of the authorizer this module created, null when one was supplied |
| `identity_jwt_mode` | `"native"` or `"lambda"`, null when `identity_jwt` is unset |
| `identity_authorizer_function_name` | Authorizer function name, null outside lambda mode |
| `identity_authorizer_function_arn` | Authorizer function ARN, null outside lambda mode |
| `identity_authorizer_log_group_name` | Authorizer log group, the first place to read a 401, null outside lambda mode |
| `identity_api_key_prefixes` | The bearer prefixes passed through to the backend, empty outside lambda mode |
| `identity_jwt_route_keys` | The marked route keys, sorted; pass to staging-access-gate |
| `route_identity_jwt_required` | Route key to whether it requires an identity token, the audit view |

## Gotchas

- Route keys cannot end in a slash. Apply fails with `BadRequestException` while the plan is green,
  and the gateway does not normalise a trailing slash.
- A path part cannot mix a literal with a `{var}`, for example `sitemap-{name}.xml`. Use literal
  route keys instead.
- Once routes are explicit method keys, OPTIONS preflights 404 unless `cors_configuration` is set on
  the API. Curl a preflight before declaring a route flip live.
- API Gateway CORS rejects `chrome-extension://` origins at apply time with `BadRequestException`
  while the plan is green. Extensions must fetch from the service worker with `host_permissions`
  instead.
- JWT claims arrive at `authorizer.jwt.claims` as a string map, so `exp` is a string, not a number.
- An authorizer denial logs `integrationStatus` and `integrationLatency` as `-` because no
  integration ran, and `authorizerError` names the reason, so it is the first field to read for a
  401 with no integration call.
- The Lambda Web Adapter passes the request context header as plain JSON, not base64.
- Discovery and JWKS are fetched at CreateAuthorizer time, so the issuer must be live before apply.
- Gate direct invocation of the function with an `x-origin-verify` header; the authorizer only
  protects the API route.
- A resource collection needs both `ANY /path` and `ANY /path/{proxy+}`. Neither key matches the
  other's requests, so writing one silently leaves half the traffic on `$default`.
- Both map keys are Terraform addresses. Renaming an `integrations` or `routes` key destroys and
  recreates that resource.
- `$default` is created from `default_integration`, never listed in `routes`; the module rejects a
  `"$default"` routes entry.
- A route whose effective type is `NONE` or `AWS_IAM` never carries an authorizer id. Attaching one
  anyway leaves a perpetual in-place `authorizer_id` diff on every later plan.
- Marking a route `require_identity_jwt` under `identity_jwt` moves it between two route resources,
  so the plan says replaced, not updated in place. Mark routes in the same apply that first sets
  `identity_jwt`.
- `identity_jwt` with no route setting `require_identity_jwt` fails a precondition: the authorizer
  would attach to nothing.
- A `route_settings` key naming no route is rejected at plan time. API Gateway would accept it and
  apply it to nothing.
- Pass `aws_acm_certificate_validation.<name>.certificate_arn`, not the certificate's own `arn`, so
  the custom domain waits for validation.
- `zone_id` writes the alias record with the module's own `aws` provider, so the zone must be in the
  same account. Leave it null and write the record yourself otherwise.
- An API with no `integrations` is accepted only alongside no `routes` and a null
  `default_integration`. That is the bootstrap shape: a fresh account builds the API, its stage, log
  group and custom domain before any function image exists, and a later apply adds the backends and
  their routes. Any route with an empty `integrations` is still refused.
- `zone_id` is unknown at plan time whenever the hosted zone is created by the same apply, and the
  alias record's count cannot be derived from an unknown value: Terraform stops with `Invalid count
  argument` rather than deferring it. Pass `dns_record_enabled` as a literal boolean from the switch
  the consumer already knows, for example its custom domain flag, and a fresh account creates the
  zone and the record in one apply. Leave it null and the count derives from the id as before.
- Changing `lambda_permission_statement_id` replaces the permission, a moment with no permission at
  all.
- API Gateway's native JWT authorizer rejects any bearer that is not a JWT before the request reaches
  anything of ours, so an agent API key gets a 401 the backend never sees and no module input can
  change that. Admitting API keys at the gateway needs a REQUEST authorizer, which is what
  `identity_jwt.mode = "lambda"` builds. The module refuses `api_key_prefixes` in native mode rather
  than accept a setting that would silently admit nothing.
- Native and lambda mode hand the integration the same thing: `authorizer.jwt.claims` as a string
  map with the same keys, so a backend verifying in process cannot tell them apart. The one
  difference is that lambda mode also admits a bearer matching `api_key_prefixes` without claims,
  leaving the backend to verify the key as it already does.
- Lambda mode costs an authorizer invocation and its duration. `result_ttl_seconds` defaults to 300
  with `identity_sources = ["$request.header.Authorization"]`, so repeated calls carrying one token
  cost one invocation per five minutes per token, and the cache key is the token itself, never a
  path, so a cached allow cannot leak across routes. Set `result_ttl_seconds = 0` to disable the
  cache and pay per request. Native mode has no per request charge at all, so stay on native
  wherever API keys are not needed.
- Because the result cache is keyed on the token, revoking an API key or a session still leaves it
  admitted at the gateway for up to `result_ttl_seconds`. The backend's own verification is what
  makes a revocation immediate, so a product that needs instant revocation at the edge sets
  `result_ttl_seconds = 0`.
- The module creates the authorizer's `aws_lambda_permission` itself. A consumer does not add one.
- `jwks_fetch_timeout_ms` must leave the authorizer time to answer: the function's timeout is 10
  seconds and a precondition rejects anything above `(10 - 4) * 1000`. The default 4000 ms allows one
  retry inside the budget.
- Flipping a product to lambda mode replaces the routes, because their `authorization_type` moves
  from `JWT` to `CUSTOM`, and destroys the native authorizer. Plan it as a route flip, in the same
  apply.
