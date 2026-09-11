# terraform-aws-http-api

An API Gateway HTTP API in front of one or many Lambda functions: the API, a `$default` stage with
layered throttling and a JSON access log, one Lambda proxy integration and one invoke permission per
backend, the routes, and optionally a custom domain with its API mapping and Route 53 alias record.

**2.0** replaces the single `lambda_invoke_arn` with an `integrations` map and a `routes` map. That
is what lets an application route path prefixes to per-domain functions while `$default` still
points at the monolith, which is the shape a strangler migration needs: each prefix moves off the
monolith one map entry at a time and everything not yet claimed keeps working unchanged.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api`. The Lambda
functions, their roles and their log groups stay with the consumer; the module needs only each
function's `invoke_arn` and `function_name`.

## What it creates

```
aws_apigatewayv2_api.this                     HTTP API, optional description, optional CORS, optional execute-api switch
aws_cloudwatch_log_group.access               /aws/apigateway/<name>, retention you choose
aws_apigatewayv2_integration.this["<key>"]    one AWS_PROXY integration per integrations entry
aws_lambda_permission.this["<key>"]           one invoke permission per integrations entry
aws_apigatewayv2_route.this["<route key>"]    one per routes entry, plus "$default" from default_integration
aws_apigatewayv2_stage.default                $default, auto_deploy, default and per-route throttling, access log
aws_apigatewayv2_domain_name.this[0]          only with domain_name: REGIONAL, TLS_1_2, your certificate
aws_apigatewayv2_api_mapping.this[0]          only with domain_name: domain -> $default stage
aws_route53_record.alias[0]                   only with domain_name and zone_id: alias A record
```

## Usage

One backend, everything on `$default`. This is the 2.0 spelling of what 1.x did with
`lambda_invoke_arn`:

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

  throttling_burst_limit = 50
  throttling_rate_limit  = 25

  domain_name     = "api.example.com"
  certificate_arn = aws_acm_certificate_validation.api.certificate_arn
  zone_id         = aws_route53_zone.this.zone_id
}
```

Two prefixes carved off the monolith:

```hcl
  integrations = {
    legacy = {
      lambda_function_name = aws_lambda_function.api.function_name
      lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
    }
    posts = {
      lambda_function_name = aws_lambda_function.posts.function_name
      lambda_invoke_arn    = aws_lambda_function.posts.invoke_arn
    }
    users = {
      lambda_function_name = aws_lambda_function.users.function_name
      lambda_invoke_arn    = aws_lambda_function.users.invoke_arn
    }
  }

  default_integration = "legacy"

  routes = {
    "ANY /api/v1/posts"          = { integration = "posts" }
    "ANY /api/v1/posts/{proxy+}" = { integration = "posts" }
    "ANY /api/v1/users"          = { integration = "users" }
    "ANY /api/v1/users/{proxy+}" = { integration = "users" }
  }
```

`examples/http-api-basic` is the complete single-integration version including the certificate,
`examples/http-api-strangler` is the version above with two domains migrated, and
`examples/http-api-with-access-gate` is the staging shape.

## Routing model

`integrations` names the backends. `routes` maps a route key to one of those names. `$default` is
not written in `routes`: it is created from `default_integration`, so the module owns it and gives
it the same authorization every other route gets.

API Gateway matches the most specific route first and falls back to `$default`, so an explicit route
always wins. That is the whole mechanism behind the strangler migration and it costs one map entry
per domain.

**Two route keys per resource collection, always.** `ANY /api/v1/posts` does **not** match
`/api/v1/posts/123`, and `ANY /api/v1/posts/{proxy+}` does **not** match the bare collection path.
Write both or half the domain's traffic quietly keeps hitting the monolith and nothing errors.

Setting `default_integration = null` creates no `$default` route at all, so anything the explicit
routes do not match gets a 404 from API Gateway. That is the end state of a finished migration, not
somewhere to be during one.

Both map keys are Terraform addresses. An `integrations` key is the address of that integration and
its permission; a `routes` key is the address of that route and is also the route key API Gateway
stores. Renaming either destroys and recreates that one resource, so pick names you can live with.

## Authorization: the module applies it, not the consumer

The Portfolio inventory found a route that had been added by hand without an `authorization_type`.
API Gateway silently defaults that to `NONE`, which is an unauthenticated hole straight through the
staging access gate on one path while every other path is closed.

This module makes that impossible. `authorization_type` is decided once, in `locals.tf`, and every
route the module creates goes through it:

- `authorizer_id` set means every route is `CUSTOM` with that authorizer, `$default` included.
- `authorizer_id` null means every route is `NONE`.

`$default` cannot be created any other way, because it is synthesised from `default_integration`
rather than listed in `routes`. The module rejects a `routes` entry keyed `"$default"` for exactly
that reason.

A route that genuinely has to answer without the gate, a health check for instance, opts out
explicitly and visibly:

```hcl
  routes = {
    "GET /health" = { integration = "legacy", authorization_type = "NONE" }
  }
```

An authorizer id only goes on a route that takes one. A route whose effective `authorization_type`
is `CUSTOM` or `JWT` gets its own `authorizer_id` if it set one and `var.authorizer_id` otherwise; a
route that resolves to `NONE` or `AWS_IAM` gets no `authorizer_id` at all, even when
`var.authorizer_id` is set and even when that one route set an `authorizer_id` of its own. Those two
types take no authorizer: API Gateway accepts the create with one attached, ignores it and stores
nothing, so the route reads back `authorizer_id = ""` while the configuration still names an
authorizer, and every later plan shows a perpetual in-place update on it. Portfolio staging hit this
on `GET /.well-known/jwks.json` and `GET /.well-known/openid-configuration`, which have to stay
public because the API Gateway JWT authorizer fetches them anonymously.

`tests/routes.tftest.hcl` asserts both directions of this, including that `$default` is `CUSTOM`
when the gate is on, and that an opted-out route carries no authorizer id.

## Requiring an identity access token

`authorizer_id` above answers "may this caller reach the API at all". This answers the different
question of "who is this caller", by enforcing the identity module's access tokens at the gateway.
It is opt-in per route:

```hcl
  routes = {
    # Anonymous. A caller with no token yet is the point of each of these.
    "GET /.well-known/openid-configuration" = { integration = "identity", authorization_type = "NONE" }
    "GET /.well-known/jwks.json"            = { integration = "identity", authorization_type = "NONE" }
    "POST /api/auth/login"                  = { integration = "identity" }
    "POST /api/auth/refresh"                = { integration = "identity" }

    # Authenticated.
    "GET /api/auth/me"     = { integration = "identity", require_identity_jwt = true }
    "ANY /api/v1/{proxy+}" = { integration = "legacy", require_identity_jwt = true }
  }
```

`require_identity_jwt = true` is one statement of intent with two implementations, because an HTTP
API route takes exactly one authorizer and in staging that slot is already the gate's.

**Production.** Set `identity_jwt`, and a marked route becomes `authorization_type = "JWT"` against
an `aws_apigatewayv2_authorizer` this module creates. API Gateway verifies the RS256 signature
against the JWKS the issuer publishes, checks `iss`, `aud`, `exp` and `nbf`, and hands the claims to
the integration at `requestContext.authorizer.jwt.claims` as a map of strings. Nothing of ours runs
on the request path.

```hcl
  identity_jwt = {
    issuer   = module.identity.issuer
    audience = module.identity.audience
  }

  identity_jwt_depends_on = [module.lambda_identity]
```

**Staging.** Leave `identity_jwt` null. The routes keep the gate's authorizer exactly as they have
it today, and enforcement moves into the gate's own Lambda, which verifies the same token. The
wiring is one output into one input:

```hcl
module "gate" {
  # ...
  identity_jwt = {
    issuer   = module.identity.issuer
    audience = module.identity.audience
  }

  identity_jwt_route_keys = module.api.identity_jwt_route_keys
}
```

That works because a route key is the same string on both sides by construction: it is the map key
in `routes` here, and it is `requestContext.routeKey` in the authorizer's event. It is the route key
rather than a second authorizer resource because a payload 2.0 authorizer event does not name the
authorizer that invoked the function. `routeArn` is a route ARN and there is no authorizer id
anywhere in the event, so two authorizers over one Lambda would be indistinguishable from inside it.

### What the two environments do not share

The claims reach the application at different paths, and the gate's Lambda gets as close to the
native shape as a Lambda authorizer is allowed to. A Lambda authorizer's context always lands under
`requestContext.authorizer.lambda`, and API Gateway stringifies every value and rejects nested
objects outright, so the claims travel as one JSON string under a key literally named `jwt.claims`:

| | production | staging |
| --- | --- | --- |
| enforced by | API Gateway's JWT authorizer | the gate's Lambda authorizer |
| claims at | `requestContext.authorizer.jwt.claims` | `requestContext.authorizer.lambda["jwt.claims"]` |
| shape | map of strings | JSON string of a map of strings |

One line reads both, and every value is a string either way, so `exp` is `"1757200000"` in both and
nothing needs an environment-specific parse:

```python
auth = event["requestContext"]["authorizer"]
claims = auth.get("jwt", {}).get("claims") or json.loads(auth["lambda"]["jwt.claims"])
```

`sub`, `iss` and `exp` are also lifted out individually as `jwt.claims.sub` and so on, for a caller
that wants only the subject and would rather not parse the blob.

### Anonymous routes, which matter more than they look

The two `.well-known` routes must be `authorization_type = "NONE"` in both environments. API
Gateway's own validator fetches `<issuer>/.well-known/openid-configuration` during
`CreateAuthorizer`, from outside, with no credentials of ours, and the whole apply fails with
`BadRequestException: ... Issuer must have a valid discovery endpoint` if it does not get a document
back. Login, refresh, register, verification, password reset, the OAuth start and callback, the
passkey login options and verify, and `oauth/providers` are anonymous for the plainer reason that a
caller with no token yet is exactly who calls them. Refresh in particular must never require an
access token: it is the flow for a caller whose access token has expired.

`$default` can never be marked. It is the catch-all for every path no explicit route claims, so
requiring a token on it would turn enforcement on for paths nobody has listed.

### Ordering, and the shape of the plan

The module orders its own routes before the authorizer and the protected routes after it, which is
why the protected routes are a second resource, `aws_apigatewayv2_route.identity_jwt`. One `for_each`
cannot be both before and after the same resource: Terraform reports a cycle and refuses the graph.

The consequence worth knowing before the first apply is that a route which gains
`require_identity_jwt` under `identity_jwt` **moves between the two resources, so it is destroyed and
recreated**. For a route being switched from open to token-required that is the correct blast radius
and it is seconds of 404 on one path, but a plan says "replaced" rather than "updated in place".
Marking the routes in the same apply that first sets `identity_jwt` keeps it to one move. Staging
never sees this: with `identity_jwt` null every route stays where it is.

What Terraform cannot order is the identity function being deployed and warm behind those routes.
`depends_on` orders API calls, not their effects, and an auto-deploying stage, an
`UpdateFunctionConfiguration` that returns while `LastUpdateStatus` is still `InProgress`, and a
container image cold start all sit between `CreateRoute` returning 201 and an outside request
getting a document back. `identity_jwt_depends_on` is where the function goes, and on a first apply
it is worth applying the function and its routes in an earlier run.

`tests/identity_jwt.tftest.hcl` covers both environments, the anonymous routes staying anonymous in
each, and the two configurations the module refuses.

## Throttling: layer 1 of the rate limiting

Gateway throttling is the first layer, applied before a request reaches any function, and the one
that costs nothing to run.

- `throttling_burst_limit` and `throttling_rate_limit` set the stage's `default_route_settings`.
  They cover every route that has no override, `$default` included.
- `route_settings` overrides one route at a time, keyed by route key exactly as `routes` is, plus
  `"$default"` for the default route. Use it to give an expensive path a tighter ceiling than the
  rest of the API without lowering the whole stage.

```hcl
  throttling_burst_limit = 200
  throttling_rate_limit  = 100

  route_settings = {
    "$default" = {
      throttling_burst_limit = 100
      throttling_rate_limit  = 50
    }
    "POST /api/v1/reports" = {
      throttling_burst_limit   = 5
      throttling_rate_limit    = 2
      detailed_metrics_enabled = true
    }
  }
```

A `route_settings` key that names no route is rejected at plan time. API Gateway accepts such a
setting and then applies it to nothing, which is a limit you believe you have and do not.

`detailed_metrics_enabled` at the top level turns per-route CloudWatch metrics on for the whole
stage, and per route inside `route_settings` turns them on for one route. It stays off by default:
with a per-prefix API that is one metric dimension per prefix.

## Custom domain, certificate and DNS

Unchanged from 1.x. The module takes `certificate_arn` as an input instead of issuing the
certificate itself. Both consumers validate their API certificate by DNS, but they write the
validation records through different providers: CarModPicker into a zone in its own account with the
default provider, WebbPulse-Portfolio production into a zone in the management account through its
`aws.dns` provider alias. A module that owned the certificate would have to own that provider choice
too, which means `configuration_aliases` and a `providers` map on every consumer, including the ones
that do not need it. So the certificate and its validation records stay with the consumer, and the
consumer passes `aws_acm_certificate_validation.<name>.certificate_arn` (not the certificate's own
`arn`) so the custom domain is created only after the certificate is issued.

The alias record follows the same reasoning. With `zone_id` set, the module writes the A record using
its own `aws` provider, so it fits any consumer whose zone is in the same account as the API.
WebbPulse-Portfolio production writes `api.webbpulse.com` cross-account through `aws.dns`, so it
leaves `zone_id` null and keeps its own `aws_route53_record`, pointing at
`custom_domain_target_domain_name` and `custom_domain_hosted_zone_id`.

## Pairing with staging-access-gate

The [`staging-access-gate`](../staging-access-gate/) module creates a REQUEST authorizer on the API
that admits only requests carrying the header CloudFront adds on its way to the API origin. This
module wires that in with two inputs:

- `disable_execute_api_endpoint = true` turns off the `https://<api-id>.execute-api...` hostname, so
  the custom domain is the only way in.
- `authorizer_id = module.gate.http_api_authorizer_id` puts `authorization_type = "CUSTOM"` with
  that authorizer on every route the module creates.

The two modules reference each other (the gate needs `api_id`, the API needs the authorizer id).
That is fine: Terraform orders resources, not modules, and the chain is API, then authorizer, then
routes. A consumer gates both inputs on the `staging_access_gate` workspace variable so that
production, where the variable is absent, plans a no-op:

```hcl
disable_execute_api_endpoint = var.staging_access_gate
authorizer_id                = var.staging_access_gate ? module.gate[0].http_api_authorizer_id : null
```

Switching the gate on updates every route in place and updates the API in place. Nothing is
replaced. Adding a prefix later picks the gate up automatically, because the authorizer is applied
by the module rather than written per route.

## CORS

`cors_configuration` is null by default, which creates no `cors_configuration` block at all. That is
what an API whose function sets its own CORS headers has in state, and it is what both applications
run today, so leaving it unset is the zero-change choice.

Set it only if you want API Gateway to answer preflight itself, without invoking any integration.
Configuring both places and having them disagree is a bad afternoon. The module rejects
`allow_credentials = true` together with `allow_origins = ["*"]`, which browsers refuse anyway.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | API name; also the default log group name suffix, `/aws/apigateway/<name>` | required |
| `description` | API description, null for none | `null` |
| `integrations` | Map of backend name to `{ lambda_function_name, lambda_invoke_arn, payload_format_version?, timeout_milliseconds?, lambda_permission_statement_id? }` | required |
| `default_integration` | Which `integrations` key serves `$default`; null creates no `$default` route | `"legacy"` |
| `routes` | Map of route key to `{ integration, authorization_type?, authorizer_id?, authorization_scopes?, require_identity_jwt? }` | `{}` |
| `payload_format_version` | Default payload format for integrations that set none, `1.0` or `2.0` | `"2.0"` |
| `throttling_burst_limit` | Stage default route burst limit | `50` |
| `throttling_rate_limit` | Stage default route requests per second | `25` |
| `route_settings` | Per-route overrides of `{ throttling_burst_limit?, throttling_rate_limit?, detailed_metrics_enabled? }`, keyed by route key or `"$default"` | `{}` |
| `detailed_metrics_enabled` | Per-route CloudWatch metrics for the whole stage | `false` |
| `access_log_group_name` | Log group name, null for `/aws/apigateway/<name>` | `null` |
| `access_log_retention_days` | Log group retention, a value CloudWatch accepts | `14` |
| `access_log_format` | Field name to `$context` variable; stored as `jsonencode()` with sorted keys | 14 fields, see `variables.tf` |
| `lambda_permission_statement_id` | Base `statement_id` of the invoke permissions; see below | `"AllowHttpApiInvoke"` |
| `disable_execute_api_endpoint` | Turn off the execute-api hostname; requires `domain_name` | `false` |
| `authorizer_id` | Authorizer for every route (`CUSTOM`), null for `NONE`. Never applied to a route whose effective type is `NONE` or `AWS_IAM` | `null` |
| `identity_jwt` | `{ issuer, audience, name?, audiences?, identity_sources? }`; creates the native JWT authorizer and puts marked routes behind it. Production only | `null` |
| `identity_jwt_depends_on` | What must already be serving the discovery document before the authorizer is created, usually the identity function's module | `[]` |
| `cors_configuration` | API-level CORS; null creates no block | `null` |
| `domain_name` | Custom hostname; null for no custom domain | `null` |
| `certificate_arn` | Issued ACM certificate in this region; required with `domain_name` | `null` |
| `zone_id` | Route 53 zone for the alias record, same account as the API; null to manage DNS yourself | `null` |
| `domain_name_tags` | Extra tags on the custom domain only | `{}` |
| `tags` | Tags on the API, stage, log group and custom domain | `{}` |

`lambda_permission_statement_id` is used verbatim when there is only one integration, and otherwise
for the `default_integration` entry, with every other integration getting
`<lambda_permission_statement_id>-<key>`. Two permissions on the same function need distinct
statement ids, and an adopting consumer needs its one existing permission to keep the id already in
state. Both hold under that rule. Override it per entry if a backend needs something else.

## Outputs

| Name | Description |
| --- | --- |
| `api_id` | API id; give it to staging-access-gate as `http_api_id` |
| `api_arn` | API ARN |
| `execution_arn` | Execution ARN prefix |
| `api_endpoint` | The execute-api endpoint (answers 403 once disabled) |
| `stage_id` | `$default` stage id |
| `stage_arn` | `$default` stage ARN |
| `integration_ids` | Integration ids keyed by `integrations` key |
| `default_integration_id` | Id of the integration behind `$default`, null when there is none. The 1.x `integration_id` under its new name |
| `route_ids` | Route ids keyed by route key, `$default` included |
| `route_integrations` | Which integration serves each route key; read it in a plan to see how much of the monolith is left |
| `identity_jwt_authorizer_id` | Id of the JWT authorizer, null when `identity_jwt` is unset |
| `identity_jwt_authorizer_name` | Name of the JWT authorizer, null when unset |
| `identity_jwt_route_keys` | The marked route keys, sorted. Pass it to `staging-access-gate`'s `identity_jwt_route_keys` |
| `route_identity_jwt_required` | Route key to whether it requires a token; the audit view |
| `lambda_permission_statement_ids` | `statement_id` of each invoke permission, keyed by `integrations` key |
| `access_log_group_name` | Access log group name |
| `access_log_group_arn` | Access log group ARN |
| `domain_name` | The custom hostname, null when none |
| `custom_domain_target_domain_name` | Regional hostname to alias to, null when none |
| `custom_domain_hosted_zone_id` | Hosted zone id of that hostname, null when none |
| `api_url` | `https://<domain_name>`, or `api_endpoint` without a domain; publish this as the API URL |

## Adoption from 1.x

2.0 is a major bump because three inputs are gone and two resource addresses changed.

| 1.x | 2.0 |
| --- | --- |
| `lambda_invoke_arn`, `lambda_function_name` | one `integrations` entry |
| `route_keys = [...]` | `routes` and `default_integration` |
| `payload_format_version` (per API) | still there as the default; per entry inside `integrations` |
| `integration_timeout_milliseconds` | `timeout_milliseconds` inside the `integrations` entry |
| `aws_apigatewayv2_integration.lambda` | `aws_apigatewayv2_integration.this["<key>"]` |
| `aws_lambda_permission.api` | `aws_lambda_permission.this["<key>"]` |
| `aws_apigatewayv2_route.this["<route key>"]` | **unchanged**, same address |
| output `integration_id` | `default_integration_id`, or `integration_ids["<key>"]` |

### The two moved blocks, and why they are inside the module

A `moved` block requires a constant index. Terraform rejects `to = aws_apigatewayv2_integration.this[var.key]`
with "A single static variable reference is required", so the module cannot move the 1.x resources
to a key the consumer chooses. It ships the two blocks for the fixed key **`legacy`** instead, in
`moved.tf`:

```hcl
moved {
  from = aws_apigatewayv2_integration.lambda
  to   = aws_apigatewayv2_integration.this["legacy"]
}

moved {
  from = aws_lambda_permission.api
  to   = aws_lambda_permission.this["legacy"]
}
```

So **an adopting consumer names its existing single backend `legacy`**. That is the entire cost of
the upgrade: rename nothing in AWS, call one map key `legacy`, and both resources move rather than
being replaced. The blocks are inert for a consumer with no 1.x state at those addresses and inert
for one whose map has no `legacy` key, so they are safe to leave in place; a later major can drop
them.

The routes need no `moved` block. In 1.x a route's address was
`aws_apigatewayv2_route.this["<route key>"]` and in 2.0 it still is, because the `for_each` key is
still the route key. **A consumer that keeps its route keys keeps its route addresses.**

### What would still be replaced

Nothing, for either consumer, on the adoption commit. The list is empty by design:

- The integration and the permission **move**, they are not replaced, because of the two blocks
  above and because the `legacy` entry reproduces every attribute of the 1.x integration (same
  `integration_uri`, same `payload_format_version`, same `timeout_milliseconds`).
- The permission keeps its `statement_id`, because `lambda_permission_statement_id` is used verbatim
  for a one-integration API. A changed `statement_id` would be a replace and a moment with no invoke
  permission at all, so this is the one input to get right.
- Every route keeps its address and its `route_key`, so routes are untouched.
- The API, stage, log group, custom domain, mapping and alias record are not addressed differently
  and not configured differently.

The one thing that **is** a replace, later and deliberately: a route whose `route_key` changes. A
route key is both the Terraform address and the API Gateway identity of the route, so changing
`"ANY /{proxy+}"` to something else destroys that route and creates the new one. That matters to
Portfolio on its first strangler step, where retiring `ANY /{proxy+}` and `ANY /` in favour of
`$default` is 1 to add and 2 to destroy on the routes. It is not part of the 2.0 adoption commit and
should be its own change, and because `$default` is created before the old routes are destroyed
within a single apply there is no window where a path has nowhere to go. Do it in that order or keep
both, which is also valid: `ANY /{proxy+}` and `$default` can coexist pointing at the same backend.

### CarModPicker

Route keys today: `["$default"]`. Statement id: the module default. Adoption is the `integrations`
map and nothing else.

```hcl
module "api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api"
  version = "~> 2.0"

  name        = "${local.prefix}-api"
  description = "CarModPicker ${var.environment} API (Lambda proxy)"

  integrations = {
    legacy = {
      lambda_function_name = module.lambda_api.function_name
      lambda_invoke_arn    = module.lambda_api.invoke_arn
      timeout_milliseconds = 29000
    }
  }

  default_integration = "legacy"
  # routes stays empty: everything is still on $default.

  throttling_burst_limit    = var.api_throttle_burst_limit
  throttling_rate_limit     = var.api_throttle_rate_limit
  access_log_retention_days = 14
  # access_log_format and lambda_permission_statement_id: the module defaults are our values.

  disable_execute_api_endpoint = local.staging_gate_enabled
  authorizer_id                = local.staging_gate_enabled ? module.staging_access_gate[0].http_api_authorizer_id : null

  domain_name      = local.custom_domain ? "api.${local.domain_name}" : null
  certificate_arn  = module.api_certificate.certificate_arn
  zone_id          = local.custom_domain ? module.staging_dns.zone_id : null
  domain_name_tags = { Name = "${local.prefix}-api-domain" }
}
```

No `moved` block in the consumer: the module's own two do the work. Expected plan: **0 to add,
0 to change, 0 to destroy, 2 moved.**

Its first strangler step is purely additive, because `$default` already exists:

```hcl
  integrations = {
    legacy = { ... }
    parts = {
      lambda_function_name = module.lambda_parts.function_name
      lambda_invoke_arn    = module.lambda_parts.invoke_arn
      timeout_milliseconds = 29000
    }
  }

  routes = {
    "ANY /api/parts"          = { integration = "parts" }
    "ANY /api/parts/{proxy+}" = { integration = "parts" }
  }
```

which is 1 integration, 1 permission and 2 routes to add, and 0 to destroy.

### WebbPulse-Portfolio

Route keys today: `["ANY /{proxy+}", "ANY /"]`, no `$default`. Statement id:
`"AllowAPIGatewayInvoke"`. Keep both route keys and set `default_integration = null` so the
adoption commit adds no route.

```hcl
module "api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api"
  version = "~> 2.0"

  name = "${local.prefix}-api"

  integrations = {
    legacy = {
      lambda_function_name = module.lambda_api.function_name
      lambda_invoke_arn    = module.lambda_api.invoke_arn
      # timeout_milliseconds: never set today, so leave it out.
    }
  }

  # Portfolio's monolith is reached through its two explicit route keys, not $default. Keeping it
  # that way is what makes the adoption plan zero-add; $default arrives on the first strangler step.
  default_integration = null

  routes = {
    "ANY /{proxy+}" = { integration = "legacy" }
    "ANY /"         = { integration = "legacy" }
  }

  throttling_burst_limit         = 200
  throttling_rate_limit          = 100
  access_log_retention_days      = 30
  lambda_permission_statement_id = "AllowAPIGatewayInvoke"

  access_log_format = {
    requestId               = "$context.requestId"
    ip                      = "$context.identity.sourceIp"
    requestTime             = "$context.requestTime"
    httpMethod              = "$context.httpMethod"
    routeKey                = "$context.routeKey"
    path                    = "$context.path"
    status                  = "$context.status"
    responseLength          = "$context.responseLength"
    integrationErrorMessage = "$context.integrationErrorMessage"
    integrationLatency      = "$context.integrationLatency"
  }

  disable_execute_api_endpoint = local.staging_gate_enabled
  authorizer_id                = local.staging_gate_enabled ? one(module.staging_access_gate[*].http_api_authorizer_id) : null

  domain_name     = local.custom_domains_enabled ? local.api_host : null
  certificate_arn = module.api_certificate.certificate_arn
  # zone_id stays null: production writes api.webbpulse.com cross-account through aws.dns.
}
```

`aws_route53_record.api` in `route53.tf` is unchanged; it still reads
`module.api.custom_domain_target_domain_name` and `module.api.custom_domain_hosted_zone_id`.

Expected plan: **0 to add, 0 to change, 0 to destroy, 2 moved.**

Its first strangler step is the one that also retires the two catch-all route keys:

```hcl
  default_integration = "legacy"

  routes = {
    "ANY /api/v1/posts"          = { integration = "posts" }
    "ANY /api/v1/posts/{proxy+}" = { integration = "posts" }
  }
```

which is 1 integration, 1 permission and 3 routes to add (`$default` plus the two posts routes) and
2 routes to destroy (`ANY /{proxy+}` and `ANY /`). Keeping the two old keys alongside `$default` is
the zero-destroy alternative if the replacement is not wanted in the same change.

### Output renames

`integration_id` is gone. `default_integration_id` is the drop-in replacement for a consumer with a
`default_integration`, and `integration_ids["legacy"]` is the replacement otherwise. Neither
consumer reads `integration_id` today, so neither needs a change.

## Not covered

Stage variables, more than one stage, non-Lambda integration types (HTTP_PROXY, service
integrations), mutual TLS on the domain, and an `api_mapping_key` for path-prefixed mappings. JWT
authorizers are half covered: a route can carry `authorization_type = "JWT"` with its own
`authorizer_id` and `authorization_scopes`, but the module does not create the authorizer. Each is an
additive input if an application needs it.

## Tests

`tests/*.tftest.hcl` are plan-only and never call AWS, so `terraform test` in this directory needs
credentials for nothing.

```
cd modules/http-api && terraform init -backend=false && terraform test
```

`routes.tftest.hcl` covers the routing model and the authorization guarantee, `throttling.tftest.hcl`
covers the two throttling layers and the per-integration overrides, and `adoption.tftest.hcl`
reproduces both consumers' 1.x shapes and asserts the addresses and statement ids that make their
adoption plans zero-destroy.
