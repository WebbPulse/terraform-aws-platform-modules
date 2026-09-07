# terraform-aws-lambda-function

The scaffolding every application Lambda function needs before it can do anything useful: an IAM
execution role with a service assume role policy, a CloudWatch log group with a retention you
choose, and the function itself with its tracing, logging, environment, architecture, memory and
timeout, seeded with a placeholder package whose code attributes are then ignored so a deployment
pipeline owns the code. It is the shape both application estates already run by hand, lifted into
one place so a change to the pattern reaches every application on its next plan.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function`. Pair it
with [`http-api`](../http-api/), which takes this module's `invoke_arn` and `function_name`.

## What it creates

```
aws_iam_role.this                 execution role, assume role policy for the service principals
aws_cloudwatch_log_group.this     /aws/lambda/<function_name> by default, retention you choose
aws_lambda_function.this          the function, code attributes under lifecycle ignore_changes
```

## What it deliberately does not create

**The permission policies on the execution role.** The two applications grant wildly different
things: CarModPicker attaches four separate `aws_iam_role_policy` resources (DynamoDB, SES, S3 and
a runtime policy for Secrets Manager, logs and X-Ray), WebbPulse-Portfolio attaches one inline
`jsonencode` policy covering logs, X-Ray, DynamoDB, SSM and KMS. Those are application permissions,
not scaffolding, and a module that owned them would have to own every application's data model. The
module creates the role and exposes `role_id`, `role_name` and `role_arn`; the application attaches
whatever it needs:

```hcl
resource "aws_iam_role_policy" "runtime" {
  name   = "runtime"
  role   = module.api_lambda.role_id
  policy = data.aws_iam_policy_document.runtime.json
}
```

`role_id` is the value `aws_iam_role_policy.role` wants. A policy that scopes itself to the
function's own log group uses `"${module.api_lambda.log_group_arn}:*"`.

**The placeholder package.** The `archive_file` that produces the seed zip stays with the
application, because the two build it in incompatible ways: CarModPicker zips
`terraform/lambda_placeholder/`, a directory in its repository, and WebbPulse-Portfolio synthesises
one from inline `source` blocks and then uploads it to an artifacts bucket as an `aws_s3_object`.
Neither is expressible as the other, `path.module` inside a module resolves to the module's own
directory rather than the application's, and a `data` source is not in state so no `moved` block
could relocate it anyway. The application keeps the archive and passes the result through `code`.

## Two ways to deliver code

`code` is one object with two shapes, so one variable covers both applications.

A local zip, which is CarModPicker:

```hcl
code = {
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256
}
```

An object in S3, which is WebbPulse-Portfolio:

```hcl
code = {
  s3_bucket        = aws_s3_bucket.lambda_artifacts.id
  s3_key           = aws_s3_object.lambda_placeholder.key
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256
}
```

Exactly one of `filename`, `s3_bucket` or `image_uri` may be set, and `s3_bucket` and `s3_key` go
together; both rules are validations, so a wrong combination fails at plan time rather than apply
time.

Either way this is only the seed. `filename`, `source_code_hash`, `s3_bucket`, `s3_key` and
`s3_object_version` are all in the function's `lifecycle` `ignore_changes` list, so once a
deployment pipeline has called `UpdateFunctionCode` the next plan leaves the running code alone.
That list is fixed rather than an input: Terraform requires `ignore_changes` to be a static list of
attribute names, so it cannot be driven by a variable. It is the union of what the two applications
ignore today, and ignoring an attribute that is not drifting is a no-op, which is why
WebbPulse-Portfolio picks up `filename` and `s3_bucket` for free without a diff.

## Logging

Lambda's own `logging_config` and the log group are two separate things, and the two applications
made different historical choices in both. The module takes them as three inputs.

- `log_format` is `JSON` or `Text`. `application_log_level` and `system_log_level` only mean
  anything under `JSON`; leave them null with `Text`.
- `set_logging_config_log_group` names the log group explicitly inside `logging_config`. Both
  settings point at the same group, because the module's group is
  `/aws/lambda/<function_name>`, which is where Lambda writes anyway. Which one is in state is
  historical, and flipping it is an in place update of the function, so match what the application
  has rather than picking a side.

CarModPicker is `JSON` with both levels at `INFO` and no explicit group. WebbPulse-Portfolio is
`Text` with the group named. `log_retention_days` is validated against the values CloudWatch Logs
actually accepts, so a typo fails at plan time.

## Ordering against the application's own policies

Both applications put a `depends_on` on the function today, naming an IAM role policy that now
lives outside the module: CarModPicker `aws_iam_role_policy.lambda_api_runtime`, WebbPulse-Portfolio
`aws_iam_role_policy.lambda_api`. Terraform cannot express a `depends_on` from inside a module to a
resource in the caller, and there is no safe way to fake one, because routing a resource attribute
through an input makes the attribute unknown at plan time and can force a replacement.

For an existing function this has no effect at all: `depends_on` orders creation, and nothing is
being created. On a greenfield apply, where the ordering does matter, put the `depends_on` on the
module block:

```hcl
module "api_lambda" {
  source = "..."
  # ...
  depends_on = [aws_iam_role_policy.runtime]
}
```

That is the supported idiom and it produces the same ordering. Both adoption plans below were
proved with the `depends_on` simply dropped, and both are clean.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `function_name` | Function name as-is, not a prefix | required |
| `runtime` | Managed runtime identifier, for example `python3.13` | required |
| `handler` | Entry point in the package | required |
| `code` | Where the seed package comes from; see above | required |
| `role_name` | Execution role name, null for `<function_name>-role` | `null` |
| `role_path` | IAM path of the role | `"/"` |
| `role_description` | Description on the role, null for none | `null` |
| `permissions_boundary_arn` | Permissions boundary on the role | `null` |
| `assume_role_service_principals` | Principals allowed to assume the role | `["lambda.amazonaws.com"]` |
| `role_tags` | Extra tags on the role only | `{}` |
| `architectures` | Exactly one of `["x86_64"]` or `["arm64"]` | `["x86_64"]` |
| `memory_size` | Memory in MB, 128 to 10240 | `128` |
| `timeout` | Seconds, 1 to 900; 29 or less behind an HTTP API | `3` |
| `description` | Description on the function, null for none | `null` |
| `publish` | Publish a numbered version on every change | `false` |
| `reserved_concurrent_executions` | Reserved concurrency, null for none | `null` |
| `environment_variables` | Environment variables; an empty map omits the block | `{}` |
| `tracing_mode` | `Active`, `PassThrough`, or null to omit the block | `"Active"` |
| `layers` | Layer ARNs, at most 5 | `[]` |
| `log_group_name` | Log group name, null for `/aws/lambda/<function_name>` | `null` |
| `log_retention_days` | Retention, a value CloudWatch Logs accepts; 0 never expires | `14` |
| `log_group_kms_key_id` | KMS key for the log group | `null` |
| `log_group_tags` | Extra tags on the log group only | `{}` |
| `log_format` | `JSON` or `Text` | `"JSON"` |
| `application_log_level` | Only meaningful with `JSON` | `null` |
| `system_log_level` | Only meaningful with `JSON` | `null` |
| `set_logging_config_log_group` | Name the log group inside `logging_config` | `false` |
| `vpc_config` | `{ subnet_ids, security_group_ids }`, null to stay outside a VPC | `null` |
| `ephemeral_storage_size` | Size of `/tmp` in MB, null for the 512 default | `null` |
| `tags` | Extra tags on the function only | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `function_name` | Function name, for an invoke permission or an alarm dimension |
| `function_arn` | Function ARN, unqualified |
| `invoke_arn` | Give this to http-api as `lambda_invoke_arn` |
| `qualified_arn` | ARN of the latest published version, empty unless `publish` |
| `qualified_invoke_arn` | Invoke ARN of the latest published version |
| `version` | Latest published version, `$LATEST` unless `publish` |
| `role_name` | Execution role name |
| `role_id` | Execution role id, which is what `aws_iam_role_policy.role` takes |
| `role_arn` | Execution role ARN |
| `role_unique_id` | Stable unique id of the role |
| `log_group_name` | Log group name |
| `log_group_arn` | Log group ARN; a logs policy appends `:*` to it |

## Adoption

Both applications move their three resources into the module with `moved` blocks. The inputs below
reproduce every attribute each application has in state today, so both adoption plans are
"3 moved, 0 to add, 0 to change, 0 to destroy". Both were proved with a speculative plan on the
staging workspace before this module was released.

One attribute is worth knowing about. The two applications write their assume role policy
differently, CarModPicker through `data.aws_iam_policy_document`, WebbPulse-Portfolio through
`jsonencode`, and those produce different JSON text. The module uses the policy document form for
both. That plans clean anyway, because the provider compares assume role policies semantically
rather than as strings, which the WebbPulse-Portfolio plan below confirms.

### CarModPicker

`terraform/lambda.tf` keeps its four policy documents, its four `aws_iam_role_policy` resources,
the `archive_file` and the `lambda_environment` local, and loses `aws_iam_role.lambda_api`,
`aws_cloudwatch_log_group.lambda_api` and `aws_lambda_function.api`. In
`data.aws_iam_policy_document.lambda_api_runtime`, `aws_cloudwatch_log_group.lambda_api.arn`
becomes `module.lambda_api.log_group_arn`, and each policy's `role` becomes
`module.lambda_api.role_id`. Elsewhere, `aws_lambda_function.api.function_name` becomes
`module.lambda_api.function_name` in `apigateway.tf`, `monitoring.tf` and `outputs.tf`, and
`aws_lambda_function.api.arn` becomes `module.lambda_api.function_arn` in `iam_github_actions.tf`
and `outputs.tf`.

```hcl
module "lambda_api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function"
  version = "~> 1.6"

  function_name = "${local.prefix}-api"
  role_name     = "${local.prefix}-lambda-api"

  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  architectures = ["x86_64"]
  memory_size   = 1024
  timeout       = 29

  code = {
    filename         = data.archive_file.lambda_placeholder.output_path
    source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256
  }

  environment_variables = local.lambda_environment

  log_retention_days    = 14
  log_format            = "JSON"
  application_log_level = "INFO"
  system_log_level      = "INFO"

  tags = { Name = "${local.prefix}-api" }
}

moved {
  from = aws_iam_role.lambda_api
  to   = module.lambda_api.aws_iam_role.this
}

moved {
  from = aws_cloudwatch_log_group.lambda_api
  to   = module.lambda_api.aws_cloudwatch_log_group.this
}

moved {
  from = aws_lambda_function.api
  to   = module.lambda_api.aws_lambda_function.this
}
```

`tracing_mode` and `role_path` are left at their defaults, `Active` and `/`, which are the values
already in state.

### WebbPulse-Portfolio

`terraform/lambda.tf` keeps the artifacts bucket and its four configuration resources, the
`archive_file`, the `aws_s3_object` placeholder, `data.aws_kms_alias.ssm` and the single
`aws_iam_role_policy.lambda_api`, and loses `aws_iam_role.lambda_api`,
`aws_cloudwatch_log_group.lambda_api` and `aws_lambda_function.api`. In that policy, `role` becomes
`module.lambda_api.role_id` and `aws_cloudwatch_log_group.lambda_api.arn` becomes
`module.lambda_api.log_group_arn`. Elsewhere, `aws_lambda_function.api.function_name` becomes
`module.lambda_api.function_name` in `apigateway.tf` and `outputs.tf`, and
`aws_lambda_function.api.arn` becomes `module.lambda_api.function_arn` in `iam_github_actions.tf`.

```hcl
module "lambda_api" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/lambda-function"
  version = "~> 1.6"

  function_name = local.lambda_function_name
  role_name     = "${local.prefix}-api-lambda"

  runtime       = "python3.13"
  handler       = "app.lambda_handler.handler"
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 15

  code = {
    s3_bucket        = aws_s3_bucket.lambda_artifacts.id
    s3_key           = aws_s3_object.lambda_placeholder.key
    source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256
  }

  environment_variables = {
    DYNAMODB_TABLE_PREFIX        = local.prefix
    SSM_PARAMETER_PREFIX         = "/${local.prefix}"
    ENVIRONMENT                  = var.environment
    CORS_ORIGINS                 = local.cors_origins
    SITE_URL                     = local.frontend_url
    LOG_LEVEL                    = "INFO"
    POWERTOOLS_SERVICE_NAME      = "webbpulse-api"
    POWERTOOLS_METRICS_NAMESPACE = "WebbPulse"
  }

  log_retention_days           = 30
  log_format                   = "Text"
  set_logging_config_log_group = true
}

moved {
  from = aws_iam_role.lambda_api
  to   = module.lambda_api.aws_iam_role.this
}

moved {
  from = aws_cloudwatch_log_group.lambda_api
  to   = module.lambda_api.aws_cloudwatch_log_group.this
}

moved {
  from = aws_lambda_function.api
  to   = module.lambda_api.aws_lambda_function.this
}
```

`application_log_level` and `system_log_level` stay null under `Text`, and `tags` stays empty:
this function carries only the provider's `default_tags` today.
