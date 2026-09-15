# terraform-aws-app-secrets

Manages one estate's AWS Secrets Manager secrets as a map, each secret taking its value from one of
five shapes. It also renders an IAM policy granting read access to exactly those secrets, so the
grant cannot drift away from what exists.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets`.

## Usage

```hcl
module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 2.22"

  name_prefix = local.prefix

  secrets = {
    "app" = {
      description = "JSON map of runtime secrets read by the Lambda API at cold start"
      version     = 1
      json = {
        SECRET_KEY = var.secret_key
      }
    }

    "session" = {
      generate        = true
      generate_length = 64
      version         = 1
    }
  }
}
```

Values are written through the `secret_string_wo` write-only argument, so no secret value reaches
Terraform state or plan output. Terraform cannot compare a value it never keeps, so it writes only
when a secret's `version` counter changes: bump `version` to publish a changed `value` or `json`, or
to rotate a generated entry.

A secret takes at most one of `generate` (an ephemeral `random_password` made here), `value` (a
string passed in), `json` (a map composed into one JSON object), `placeholder` (a literal seeded once
with `ignore_changes` so an operator overwrites it out of band), or none of them (created empty, with
no Terraform-managed version at all).

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `secrets` | Map of secrets to manage, keyed by short name; see the shape below | required |
| `name_prefix` | Put in front of every key to form the secret name; empty uses the key alone | `""` |
| `name_separator` | Single character joining prefix and key, one of `/ _ + = . @ -` | `"/"` |
| `recovery_window_in_days` | Default recovery window, 0 or 7 to 30; a secret may override | `0` |
| `kms_key_id` | Default KMS key id, alias or ARN; null uses `aws/secretsmanager` | `null` |
| `tags` | Tags on every secret, on top of the provider `default_tags` | `{}` |
| `create_empty_version` | Give a secret with no value an empty version resource anyway | `false` |
| `description_default` | Description for any secret that sets none | `null` |
| `policy_sid` | Sid on the generated policy statement; null renders no Sid | `null` |
| `policy_actions` | Actions in the generated read policy | `["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]` |
| `policy_secret_keys` | Keys the read policy covers; null means every secret the module manages | `null` |

Each entry in `secrets`:

```hcl
{
  name        = optional(string)   # full secret name, overriding name_prefix plus the key
  description = optional(string)   # defaults to description_default
  version     = optional(number, 1) # bump to rewrite the value or to rotate generated entries

  generate                  = optional(bool, false)
  generate_length           = optional(number, 32)    # 8 to 512
  generate_special          = optional(bool, true)
  generate_override_special = optional(string)
  generate_min_special      = optional(number, 0)
  generate_min_numeric      = optional(number, 0)
  generate_min_upper        = optional(number, 0)
  generate_min_lower        = optional(number, 0)

  value       = optional(string)
  json        = optional(map(string))
  placeholder = optional(string)

  recovery_window_in_days = optional(number)          # null takes the module-wide value
  kms_key_id              = optional(string)          # null takes the module-wide value
  tags                    = optional(map(string), {})
}
```

## Outputs

| Name | Description |
| --- | --- |
| `arns` | Secret ARN per key, for an application env var such as `APP_SECRETS_ARN` |
| `names` | Full secret name per key, the secret-id for `put-secret-value` |
| `ids` | Secrets Manager id per key; the provider returns the ARN here |
| `version_ids` | Version id of each Terraform-managed version, for ordering only |
| `read_policy_json` | Policy document granting `policy_actions` on the covered secrets |
| `read_policy_statement` | The same single statement as an object, for composing one policy from several |
| `policy_resources` | The covered secret ARNs, sorted |

## Gotchas

- A secret may set at most one of `generate`, `value`, the `json` pair and `placeholder`; setting two
  fails validation at plan time. `json` and `json_generate` are the one pair that go together, because
  `json_generate` adds generated keys to the same blob rather than replacing it.
- An empty string in `value` counts as no value rather than a version holding `""`. Secrets Manager
  has no empty version. Use `create_empty_version` if the version resource must exist regardless.
- `recovery_window_in_days` defaults to 0 because Secrets Manager refuses to reuse the name of a
  secret still scheduled for deletion; a non-zero window blocks recreating the same name.
- Renaming a map key renames the secret, which replaces it. Set `name` explicitly to change the key
  without touching the secret.
- A `placeholder` secret is a separate resource with `ignore_changes` on its value, so Terraform
  never plans back over what an operator wrote. `version_ids` for it goes stale after that write.
- `json` drops entries whose value is null and keeps an empty string, so an application can tell
  "set to empty" from "absent". `jsonencode` sorts keys, so reordering the map is a no-op.
- No secret value reaches Terraform state or plan output. Every shape writes through
  `secret_string_wo`, and a generated value comes from an ephemeral `random_password` that exists
  only for the duration of the run. A value Terraform must never receive at all, even in memory,
  still belongs in `placeholder` or in a secret with no value.
- `version` is the write-only counter, and it is the only thing that triggers a write. Editing a
  `value` or a `json` entry without bumping `version` changes nothing in AWS, and the plan is empty.
  Bumping `version` rewrites that secret, which for a `generate` secret means rotating it, since the
  ephemeral generator produces a fresh value on every run.
- One read policy per module instance. A second role reading a different subset takes
  `policy_resources` and writes its own statement, or uses a second instance of the module.
- No rotation, no resource policy and no cross-region replication. Cross-account reads need
  `aws_secretsmanager_secret_policy` attached from outside using the `names` output.
- Adopting the write-only version from an earlier module version is an in-place update, not a
  replacement, for a `value`, `json` or `placeholder` secret: the provider compares the value already
  in state against the one now being written, finds them equal, and plans nothing. A `generate`
  secret is the exception, because the ephemeral generator cannot reproduce the value state holds, so
  the first plan after adoption replaces that version and rotates it.
- `json_generate` puts a generated key inside the same JSON blob, so a value the application needs
  alongside its other settings does not cost a second Secrets Manager secret. `format` is `password`
  for a character string or `bytes32-base64` for 32 raw random bytes in standard base64, which is the
  shape an HKDF or HMAC key wants. A key may not appear in both `json` and `json_generate`.
- A generated entry is minted fresh on every write of its blob, so any bump of that secret's `version`
  rotates it. Set `keep = true` on the entry once its value is live and the module reads the current
  version back and writes the same value through again, leaving it untouched while other keys in the
  blob change. Leave `keep` false only before the first write, because the read fails if the secret
  has no version yet. Rotating a kept entry on purpose means setting `keep = false` and bumping
  `version` in the same change.
- The aws provider floor is `>= 6.50`, the release that stopped replacing a version when it switches
  between `secret_string` and `secret_string_wo` without the value changing. The random provider floor
  is `>= 3.9`, which is where the ephemeral `random_bytes` landed (the ephemeral `random_password`
  arrived in 3.7), and `required_version` is `>= 1.11`, which is where write-only arguments landed.
