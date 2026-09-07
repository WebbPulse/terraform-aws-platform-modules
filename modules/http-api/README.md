# terraform-aws-http-api

An API Gateway HTTP API that proxies everything to one Lambda function: the API, a `$default`
stage with throttling and a JSON access log, the Lambda proxy integration and its invoke
permission, the routes, and optionally a custom domain with its API mapping and Route 53 alias
record. It is the shape both application estates already run by hand, lifted into one place so a
change to the pattern reaches every application on its next plan.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api`. The Lambda
function, its role and its log group stay with the consumer; the module needs only the function's
`invoke_arn` and `function_name`.

## What it creates

```
aws_apigatewayv2_api.this                    HTTP API, optional description, optional execute-api switch
aws_cloudwatch_log_group.access              /aws/apigateway/<name>, retention you choose
aws_apigatewayv2_integration.lambda          AWS_PROXY to lambda_invoke_arn, payload 2.0
aws_apigatewayv2_route.this["<route key>"]   one per route_keys entry, NONE or CUSTOM authorization
aws_apigatewayv2_stage.default               $default, auto_deploy, throttling, access log
aws_lambda_permission.api                    apigateway.amazonaws.com may invoke the function
aws_apigatewayv2_domain_name.this[0]         only with domain_name: REGIONAL, TLS_1_2, your certificate
aws_apigatewayv2_api_mapping.this[0]         only with domain_name: domain -> $default stage
aws_route53_record.alias[0]                  only with domain_name and zone_id: alias A record
```

## Usage

```hcl
module "api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api"
  version = "~> 1.2"

  name                 = "example-production-api"
  lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
  lambda_function_name = aws_lambda_function.api.function_name

  route_keys             = ["$default"]
  throttling_burst_limit = 50
  throttling_rate_limit  = 25

  domain_name     = "api.example.com"
  certificate_arn = aws_acm_certificate_validation.api.certificate_arn
  zone_id         = aws_route53_zone.this.zone_id
}
```

`examples/http-api-basic` at the repository root is the complete version of that, including the
certificate. `examples/http-api-with-access-gate` is the staging shape described below.

## Custom domain, certificate and DNS

The module takes `certificate_arn` as an input instead of issuing the certificate itself. Both
consumers validate their API certificate by DNS, but they write the validation records through
different providers: CarModPicker into a zone in its own account with the default provider,
WebbPulse-Portfolio production into a zone in the management account through its `aws.dns`
provider alias. A module that owned the certificate would have to own that provider choice too,
which means `configuration_aliases` and a `providers` map on every consumer, including the ones
that do not need it. Until the DNS ownership story is the same everywhere, the certificate and its
validation records stay with the consumer, and the consumer passes
`aws_acm_certificate_validation.<name>.certificate_arn` (not the certificate's own `arn`) so the
custom domain is created only after the certificate is issued.

The alias record follows the same reasoning. With `zone_id` set, the module writes the A record
using its own `aws` provider, so it fits any consumer whose zone is in the same account as the
API: CarModPicker in both environments, WebbPulse-Portfolio staging. WebbPulse-Portfolio production
writes `api.webbpulse.com` cross-account through `aws.dns`, so it leaves `zone_id` null and keeps
its own `aws_route53_record`, pointing at `custom_domain_target_domain_name` and
`custom_domain_hosted_zone_id`. Because the Portfolio record goes through the same alias in both
environments, the recommendation is to keep it outside the module in both, rather than move it in
staging only. If DNS writing is later unified behind a provider the module can be handed, the
record can move in with a `moved` block and the certificate can follow.

## Pairing with staging-access-gate

The [`staging-access-gate`](../staging-access-gate/) module creates a REQUEST authorizer on the
API that admits only requests carrying the header CloudFront adds on its way to the API origin.
This module wires that in with two inputs:

- `disable_execute_api_endpoint = true` turns off the `https://<api-id>.execute-api...` hostname,
  so the custom domain is the only way in.
- `authorizer_id = module.gate.http_api_authorizer_id` puts `authorization_type = "CUSTOM"` with
  that authorizer on every route. With `authorizer_id = null` every route is `NONE`.

The two modules reference each other (the gate needs `api_id`, the API needs the authorizer id).
That is fine: Terraform orders resources, not modules, and the chain is API, then authorizer, then
routes. A consumer gates both inputs on the `staging_access_gate` workspace variable so that
production, where the variable is absent, plans a no-op:

```hcl
disable_execute_api_endpoint = var.staging_access_gate
authorizer_id                = var.staging_access_gate ? module.gate[0].http_api_authorizer_id : null
```

Switching the gate on updates every route in place and updates the API in place. Nothing is
replaced.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | API name; also the default log group name suffix, `/aws/apigateway/<name>` | required |
| `description` | API description, null for none | `null` |
| `lambda_invoke_arn` | `invoke_arn` of the function | required |
| `lambda_function_name` | Name of the function, for the invoke permission | required |
| `route_keys` | Route keys, each also the `for_each` key of its route | `["$default"]` |
| `payload_format_version` | `1.0` or `2.0` | `"2.0"` |
| `integration_timeout_milliseconds` | 50 to 30000; null leaves the service default unset | `null` |
| `throttling_burst_limit` | Stage default route burst limit | `50` |
| `throttling_rate_limit` | Stage default route requests per second | `25` |
| `detailed_metrics_enabled` | Per-route CloudWatch metrics | `false` |
| `access_log_group_name` | Log group name, null for `/aws/apigateway/<name>` | `null` |
| `access_log_retention_days` | Log group retention, a value CloudWatch accepts | `14` |
| `access_log_format` | Field name to `$context` variable; stored as `jsonencode()` with sorted keys | 14 fields, see `variables.tf` |
| `lambda_permission_statement_id` | `statement_id` of the invoke permission; changing it replaces the permission | `"AllowHttpApiInvoke"` |
| `disable_execute_api_endpoint` | Turn off the execute-api hostname; requires `domain_name` | `false` |
| `authorizer_id` | Authorizer for every route (`CUSTOM`), null for `NONE` | `null` |
| `domain_name` | Custom hostname; null for no custom domain | `null` |
| `certificate_arn` | Issued ACM certificate in this region; required with `domain_name` | `null` |
| `zone_id` | Route 53 zone for the alias record, same account as the API; null to manage DNS yourself | `null` |
| `domain_name_tags` | Extra tags on the custom domain only | `{}` |
| `tags` | Tags on the API, stage, log group and custom domain | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `api_id` | API id; give it to staging-access-gate as `http_api_id` |
| `api_arn` | API ARN |
| `execution_arn` | Execution ARN prefix |
| `api_endpoint` | The execute-api endpoint (answers 403 once disabled) |
| `stage_id` | `$default` stage id |
| `stage_arn` | `$default` stage ARN |
| `integration_id` | Lambda integration id |
| `route_ids` | Route ids keyed by route key |
| `access_log_group_name` | Access log group name |
| `access_log_group_arn` | Access log group ARN |
| `domain_name` | The custom hostname, null when none |
| `custom_domain_target_domain_name` | Regional hostname to alias to, null when none |
| `custom_domain_hosted_zone_id` | Hosted zone id of that hostname, null when none |
| `api_url` | `https://<domain_name>`, or `api_endpoint` without a domain; publish this as the API URL |

## Adoption

Both applications move their existing resources into the module with `moved` blocks. The inputs
below reproduce every attribute each application has in state today, so the adoption plan is
"9 to move, 0 to add, 0 to change, 0 to destroy" apart from the outputs being re-sourced. The
proving step is the speculative plan on the staging workspace that a pull request into `staging`
triggers; check it reads exactly that before merging.

Two attribute choices are what make the plan clean and are worth knowing about:

- Setting `authorization_type = "NONE"`, `disable_execute_api_endpoint = false`,
  `detailed_metrics_enabled = false` and `tags = null` explicitly is identical to leaving them
  unset on provider 5.x; those are the values already in state.
- `integration_timeout_milliseconds` is `Optional+Computed`. An integration that never set it has
  30000 in state, and a null input leaves that alone. Passing 30000 would also plan clean, but
  null is what the configuration says today.

### CarModPicker

`terraform/apigateway.tf` is replaced by the module block; `aws_route53_record.api_lambda` leaves
`route53.tf`; `acm.tf` keeps `aws_acm_certificate.api`, `aws_route53_record.acm_api_validation`
and `aws_acm_certificate_validation.api` unchanged.

```hcl
module "api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api"
  version = "~> 1.2"

  name        = "${local.prefix}-api"
  description = "CarModPicker ${var.environment} API (Lambda proxy)"

  lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
  lambda_function_name = aws_lambda_function.api.function_name

  route_keys                       = ["$default"]
  integration_timeout_milliseconds = 29000
  throttling_burst_limit           = var.api_throttle_burst_limit
  throttling_rate_limit            = var.api_throttle_rate_limit
  access_log_retention_days        = 14
  # access_log_format and lambda_permission_statement_id: the defaults are CarModPicker's values.

  domain_name      = local.custom_domain ? "api.${local.domain_name}" : null
  certificate_arn  = local.custom_domain ? aws_acm_certificate_validation.api[0].certificate_arn : null
  zone_id          = local.custom_domain ? aws_route53_zone.carmodpicker[0].zone_id : null
  domain_name_tags = { Name = "${local.prefix}-api-domain" }
}

moved {
  from = aws_apigatewayv2_api.api
  to   = module.api.aws_apigatewayv2_api.this
}

moved {
  from = aws_cloudwatch_log_group.api_access
  to   = module.api.aws_cloudwatch_log_group.access
}

moved {
  from = aws_apigatewayv2_integration.lambda
  to   = module.api.aws_apigatewayv2_integration.lambda
}

moved {
  from = aws_apigatewayv2_route.default
  to   = module.api.aws_apigatewayv2_route.this["$default"]
}

moved {
  from = aws_apigatewayv2_stage.default
  to   = module.api.aws_apigatewayv2_stage.default
}

moved {
  from = aws_lambda_permission.api
  to   = module.api.aws_lambda_permission.api
}

moved {
  from = aws_apigatewayv2_domain_name.api
  to   = module.api.aws_apigatewayv2_domain_name.this
}

moved {
  from = aws_apigatewayv2_api_mapping.api
  to   = module.api.aws_apigatewayv2_api_mapping.this
}

moved {
  from = aws_route53_record.api_lambda
  to   = module.api.aws_route53_record.alias
}
```

Then in `locals.tf`, `api_url = module.api.api_url`, and in `outputs.tf`,
`api_invoke_url = module.api.api_endpoint`. The three `count`-indexed resources move as whole
resources, so `[0]` follows along, and in staging with the reduced profile (no custom domain) the
`from` and `to` are both empty.

### WebbPulse-Portfolio

`terraform/apigateway.tf` keeps `aws_acm_certificate.api`, `aws_route53_record.api_cert_validation`
and `aws_acm_certificate_validation.api` (they can move to `acm.tf`) and loses everything else.
`aws_route53_record.api` in `route53.tf` stays, with its alias re-pointed at the module outputs.

```hcl
module "api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/http-api"
  version = "~> 1.2"

  name = "${local.prefix}-api"
  # description: none today, so leave it null.

  lambda_invoke_arn    = aws_lambda_function.api.invoke_arn
  lambda_function_name = aws_lambda_function.api.function_name

  route_keys                     = ["ANY /{proxy+}", "ANY /"]
  throttling_burst_limit         = 200
  throttling_rate_limit          = 100
  access_log_retention_days      = 30
  lambda_permission_statement_id = "AllowAPIGatewayInvoke"
  # integration_timeout_milliseconds: never set today, so leave it null.

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

  domain_name     = local.custom_domains_enabled ? local.api_host : null
  certificate_arn = local.custom_domains_enabled ? aws_acm_certificate_validation.api[0].certificate_arn : null
  # zone_id stays null: production writes api.webbpulse.com cross-account through aws.dns.
}

resource "aws_route53_record" "api" {
  count    = local.custom_domain_count
  provider = aws.dns

  zone_id = local.records_zone_id
  name    = local.api_host
  type    = "A"

  alias {
    name                   = module.api.custom_domain_target_domain_name
    zone_id                = module.api.custom_domain_hosted_zone_id
    evaluate_target_health = false
  }
}

moved {
  from = aws_apigatewayv2_api.backend
  to   = module.api.aws_apigatewayv2_api.this
}

moved {
  from = aws_cloudwatch_log_group.apigateway_access
  to   = module.api.aws_cloudwatch_log_group.access
}

moved {
  from = aws_apigatewayv2_integration.lambda
  to   = module.api.aws_apigatewayv2_integration.lambda
}

moved {
  from = aws_apigatewayv2_route.proxy
  to   = module.api.aws_apigatewayv2_route.this["ANY /{proxy+}"]
}

moved {
  from = aws_apigatewayv2_route.root
  to   = module.api.aws_apigatewayv2_route.this["ANY /"]
}

moved {
  from = aws_apigatewayv2_stage.default
  to   = module.api.aws_apigatewayv2_stage.default
}

moved {
  from = aws_lambda_permission.apigateway
  to   = module.api.aws_lambda_permission.api
}

moved {
  from = aws_apigatewayv2_domain_name.api
  to   = module.api.aws_apigatewayv2_domain_name.this
}

moved {
  from = aws_apigatewayv2_api_mapping.api
  to   = module.api.aws_apigatewayv2_api_mapping.this
}
```

Then in `locals.tf`, `api_url = module.api.api_url`, and in `outputs.tf`,
`api_gateway_url = module.api.api_endpoint` and
`api_custom_domain = module.api.custom_domain_target_domain_name`.

Once both applications are on the module, the `moved` blocks can be deleted after one apply each.

## Not covered

CORS configuration on the API (both applications handle CORS in the function), stage variables,
more than one integration or stage, JWT authorizers, mutual TLS on the domain, and an
`api_mapping_key` (path-prefixed mappings). Each is an additive input if an application needs it.
