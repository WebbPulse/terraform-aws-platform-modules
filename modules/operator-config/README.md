# terraform-aws-operator-config

One SSM Parameter Store parameter per app and environment holding a JSON object of private,
non-secret config that an operator owns and Terraform reads. Terraform seeds it with `{}` once and
never writes it again, and exposes the live value decoded as a map. The first use is
`ses_verified_recipients`: the addresses stay out of the repository and out of HCP variables, and an
operator changes them with one CLI call.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/operator-config`.

## Usage

```hcl
module "config" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/operator-config"
  version = "~> 2.30"

  name_prefix = local.prefix
}

module "ses" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ses-identity"
  version = "~> 2.30"

  verified_recipients = try(module.config.values.ses_verified_recipients, [])
}
```

The `ses` block shows only the input this feeds; `ses-identity` takes its other inputs as usual.

An operator sets the value, carrying every key, since a put replaces the whole object:

```sh
aws ssm put-parameter --overwrite --type String \
  --name /carmodpicker-staging/config \
  --value '{"ses_verified_recipients":["owner@example.com"]}'
```

The next plan picks it up.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name_prefix` | Estate prefix, giving `/<name_prefix>/config`; no leading or trailing slash | `null` |
| `name` | Full parameter name starting with a slash, overriding `name_prefix` | `null` |
| `description` | Description on the parameter | operator-owned wording |
| `tags` | Tags on the parameter, on top of the provider `default_tags` | `{}` |

One of `name_prefix` and `name` is required.

## Outputs

| Name | Description |
| --- | --- |
| `values` | The live JSON object, decoded; read keys with `try(..., default)` |
| `name` | Full parameter name, the `--name` for `put-parameter` |
| `arn` | ARN of the parameter |
| `version` | Parameter version Terraform last refreshed |

## Gotchas

- `ignore_changes` on the value stops Terraform writing, not reading. Refresh copies the live value
  into state, so `values` follows the operator's latest put on every normal plan, and the resource
  itself plans no change. This was checked against a real parameter: after an out of band put the
  plan showed only the output change, and an apply changed zero resources and left the value alone.
  A plan with `-refresh=false` sees the value from the last apply instead.
- It is a Standard tier `String`, which is free and holds up to 4 KB. It must stay a `String`:
  the value is read through `insecure_value`, which is not sensitive, so the decoded keys can drive
  `for_each`. Switching it to `SecureString` out of band breaks the read. Anything secret belongs in
  `app-secrets` instead.
- The value lands in state and plan output in plain text. That is the point of it being non-secret
  config; do not put credentials here.
- The value must be a JSON object. Anything else fails the `values` output with an error naming the
  fix, rather than silently decoding to something a consumer indexes wrongly.
- No read policy output. Only the Terraform run role reads the parameter, and it already can; an
  application that needs these values at runtime gets them through Terraform outputs or environment.
- Destroying the module deletes the parameter and the operator's value with it.
- Why a module of its own rather than part of `app-secrets`: it is a different service with a
  different reader. `app-secrets` holds runtime secrets that never enter state and ships a read
  policy for the application role; this holds plan-time config that Terraform itself reads and is
  happy to keep in state.
