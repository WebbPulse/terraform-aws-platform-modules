# terraform-aws-staging-access-gate

Puts a CloudFront-fronted staging site, and the HTTP API behind it, behind a sign-in wall for a
fixed list of email addresses. Nothing about the application changes; the gate sits in front of it.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-access-gate`.

## Usage

```hcl
module "gate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-access-gate"
  version = "~> 1.0"

  name             = "example-staging"
  cookie_domain    = "staging.example.com"
  site_host        = "www.staging.example.com"
  additional_hosts = ["staging.example.com"]
  allowed_emails   = var.staging_access_users

  http_api_id = aws_apigatewayv2_api.api.id

  viewer_request_handler_js = local.app_handler_js
}
```

The consuming distribution must add an origin for `login_origin_domain_name` with
`login_origin_access_control_id`, `trusted_key_groups = [key_group_id]` on the default behavior, the
viewer-request function on the default, `auth_path_pattern` and `/index.html` behaviors, an ordered
behavior for `auth_path_pattern`, and an unsigned behavior for exactly `/index.html`. On the API,
set `disable_execute_api_endpoint = true` and `authorization_type = "CUSTOM"` with
`authorizer_id = module.gate.http_api_authorizer_id` on every route.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | Resource prefix and Cognito hosted UI domain prefix, for example `carmodpicker-staging` | required |
| `cookie_domain` | Staging apex the signed cookies and policy are scoped to | required |
| `site_host` | Host the browser lands on after sign-in; must be under `cookie_domain` | required |
| `additional_hosts` | Other hosts on the distribution allowed to complete the Cognito flow | `[]` |
| `allowed_emails` | Who may sign in; each becomes an invited Cognito user | required |
| `session_hours` | Signed cookie lifetime in hours, 1 to 168 | `12` |
| `auth_path_prefix` | URI prefix routed to the login Lambda | `"/_auth/"` |
| `api_path_prefix` | URI prefix the viewer-request function treats as API traffic | `"/api/"` |
| `viewer_request_handler_js` | JavaScript defining `function appHandler(event)`, run before the gate check | `""` |
| `cloudfront_distribution_arn` | Narrows the login function URL invoke permission to one distribution | `null` |
| `http_api_id` | HTTP API to attach the origin-verify REQUEST authorizer to | `null` |
| `http_api_attached` | Plan time known override for whether that authorizer is created; null derives it from `http_api_id` | `null` |
| `origin_verify_header_name` | Header CloudFront adds to API origin requests and the authorizer checks | `"x-origin-verify"` |
| `invite_login_url` | URL placed in the Cognito invitation email | `null` |
| `mfa_configuration` | Cognito MFA setting: `OFF`, `OPTIONAL` or `ON` (software token) | `"OFF"` |
| `log_retention_days` | CloudWatch Logs retention for the two Lambdas; 0 never expires | `7` |
| `identity_jwt` | Object turning on identity access token verification in the authorizer; see below | `null` |
| `identity_jwt_route_keys` | Route keys that must present a valid token; empty means the feature is off | `[]` |
| `identity_anonymous_path_prefixes` | Paths admitted with no gate credential and no token, matched as prefixes; null renders the issuer's `.well-known` subtree when enforcement is on | `null` |

```hcl
identity_jwt = {
  issuer             = string           # https, no trailing slash
  audience           = string
  jwks_url           = optional(string) # defaults to <issuer>/.well-known/jwks.json
  jwks_ttl_seconds   = optional(number) # 300
  clock_skew_seconds = optional(number) # 60
  api_key_prefixes   = optional(list(string)) # []; bearers with these prefixes pass through unverified
  jwks_fetch_timeout_ms = optional(number) # 4000; 500 to 10000, must cover a cold identity function
}
```

A bearer token on an enforced route whose value starts with one of `api_key_prefixes` is allowed
through with no claims context, for the function behind the API to verify itself. Empty, the
default, denies every bearer that is not a valid access token. A prefix may not be empty and may
not start with `ey`, which is where a JWT header begins.

## Outputs

| Name | Description |
| --- | --- |
| `key_group_id` | CloudFront key group to set as `trusted_key_groups` on every gated behavior |
| `viewer_request_function_arn` | CloudFront Function to associate as viewer-request |
| `login_origin_domain_name` | Origin domain name for the login Lambda function URL |
| `login_origin_access_control_id` | Origin access control id to set on the login origin |
| `auth_path_pattern` | Path pattern for the ordered behavior routing to the login origin |
| `api_path_pattern` | Path pattern for the ordered behavior routing to the API origin |
| `origin_verify_header_name` | Custom header name to add to the API origin |
| `origin_verify_header_value` | Custom header value to add to the API origin (sensitive) |
| `origin_verify_ssm_parameter_name` | SSM parameter holding the origin verification header value |
| `origin_verify_ssm_parameter_arn` | ARN of that SSM parameter |
| `signing_key_ssm_parameter_name` | SSM parameter holding the cookie signing private key (SecureString; the name only) |
| `signing_key_ssm_parameter_arn` | ARN of that SSM parameter, for the `ssm:GetParameter` grant |
| `signing_key_pair_id` | CloudFront public key id for the `CloudFront-Key-Pair-Id` cookie |
| `cookie_domain` | Domain the signed session cookies are scoped to |
| `http_api_authorizer_id` | Id of the HTTP API REQUEST authorizer, null when `http_api_id` was not given |
| `user_pool_id` | Cognito user pool id |
| `user_pool_client_id` | Cognito app client id used by the login Lambda |
| `hosted_ui_domain` | Base URL of the Cognito hosted UI |
| `login_function_name` | Name of the login Lambda function |
| `cache_policy_id_caching_disabled` | AWS managed CachingDisabled cache policy id |
| `origin_request_policy_id_all_viewer_except_host_header` | AWS managed AllViewerExceptHostHeader policy id |
| `identity_jwt_enforced` | Whether the authorizer additionally requires an identity access token |
| `identity_jwt_route_keys` | The route keys it requires a token on, sorted; empty when nothing is enforced |

## Design

Sign-in is a Cognito user pool (admin-create-only, hosted UI, confidential client). A login Lambda
behind a function URL exchanges the code and issues CloudFront signed cookies scoped to
`cookie_domain`, which CloudFront verifies on every key-group behavior. An HTTP API REQUEST
authorizer verifies the same cookies, or the `x-origin-verify` header, so the API host cannot be
called around the gate. The allow-list ledger fields live at `staging_access_gate/users`.

## Gotchas

- CloudFront validates the signed cookie before the viewer-request function runs, so an
  unauthenticated deep link gets a 403 rather than the function's 302 to the login page.
- The unsigned `/index.html` behavior is mandatory, not a nicety: without it the 403 fallback
  cannot fetch the SPA shell and the deep link dead-ends.
- `cookie_domain` must be the bare staging apex, and `site_host` must equal it or be a subdomain,
  otherwise the signed cookies never reach the site. Both are enforced by validation.
- Leave `cloudfront_distribution_arn` null when the distribution that consumes these outputs is the
  one fronting the login Lambda; referencing it there is a dependency cycle.
- Setting `identity_jwt` alone enforces nothing. A route key must also appear in
  `identity_jwt_route_keys`, and `$default` is rejected because it is the anonymous catch-all.
- `identity_jwt.issuer` must be https with no trailing slash; a trailing slash builds a double-slash
  JWKS URL that fetches nothing.
- A cold identity function can take about two seconds to serve the JWKS, so `jwks_fetch_timeout_ms`
  has to cover a cold start. Set it too low and the first authorized call after the TTL expires
  aborts the fetch and fails with `authorizerError=Forbidden` on a valid token.
- Only public key material belongs in `identity_anonymous_path_prefixes`. An application path there
  is a hole straight past the gate.
- A passed-through API key reaches the function with no `jwt.claims`, so only routes whose handlers
  verify the key in process, through `claims_or_api_key`, belong on an API that sets
  `api_key_prefixes`. A handler that reads `identity_subject` fails closed with a 401.
- The authorizer's identity half lives in `shared/identity-authorizer/identity.js` at the repo root,
  not in this module, and is packaged into both this authorizer and the http-api module's
  `identity_jwt.mode = "lambda"` authorizer. Token verification, JWKS caching and the API key
  prefix passthrough are therefore the same code in staging and production. Edits to it change both,
  and the node suite here is what covers it. Only the cookie, origin secret and anonymous path
  admission is this module's own.
- A route key naming no route on the API is inert rather than an error; the module is not given the
  API's route list and cannot tell a typo from a route not added yet.
- `http_api_id` is unknown at plan time whenever the API is created by the same apply, and the
  authorizer count cannot be derived from an unknown value: Terraform stops with `Invalid count
  argument` rather than deferring it. Pass `http_api_attached` as a literal boolean from the switch
  the consumer already knows, for example its staging gate flag, and a fresh account creates the API
  and attaches the gate in one apply. Leave it null and the count derives from the id as before.
- The authorizer environment must stay under Lambda's 4096 byte cap, which is only measured at apply
  time, so anything scaling with consumer configuration fails an apply on a green plan.
- The authorizer cannot cache: API Gateway keys its cache on identity sources and this one has none,
  so every request invokes it. Fine at staging traffic, not a production pattern.
- The gate answers allow or deny for the whole API. `identity_jwt_route_keys` only decides whether a
  token is demanded, never what it may do; application authorization is still the application's job.
- The signed cookies are also the API session, so `session_hours` is the longest an API client goes
  without another trip through the hosted UI. There is no refresh.
- Non-browser callers (a Chrome extension, a pipeline health check) cannot complete the hosted UI
  flow; they call the API directly with the origin-verify header read from SSM.
- A gate failure looks like a working site: if CloudFront cannot invoke the login function the 403
  becomes the SPA shell with status 200. The tell is `/_auth/login` answering with `index.html` and
  `x-cache: Error from cloudfront`. Both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` are
  required and the module grants both.
- The RSA signing key pair is generated by Terraform and therefore lives in state. Acceptable for a
  staging gate, not for production credentials.
- The signing key outputs exist so the e2e suite can mint its own session cookies in staging: grant
  the test role `ssm:GetParameter` on `signing_key_ssm_parameter_arn` there and nowhere else. The
  name and the ARN are not sensitive and are not marked so; the key stays in the SecureString.
- `allowed_emails` must be non-empty and free of case-insensitive duplicates; a duplicate fails to
  create because a Cognito username is the email.
- `name` must not contain `aws` or `cognito`: Cognito rejects hosted UI domain prefixes that do.
- Pair the API with `disable_execute_api_endpoint = true`, and allow `https://<site_host>` with
  `allow_credentials = true` in its CORS configuration; a wildcard origin is not allowed with
  credentials.
