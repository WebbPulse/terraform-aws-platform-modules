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

### Operator-owned keys

Set `json_preserve_unmanaged = true` on a `json` shape secret and the blob keeps keys an operator set
out of band with `put-secret-value`. Every write starts from the secret's current live keys, lays the
declared `json` entries on top, then the `json_generate` keys, so a `version` bump no longer drops
what Terraform does not declare. `json` may be empty or omitted, which moves every value out of
Terraform variables and into the secret itself.

```hcl
secrets = {
  "app" = {
    version                 = 2
    json_preserve_unmanaged = true
    json_generate = {
      mfa_master_key = { format = "bytes32-base64", keep = true }
    }
  }
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `secrets` | Map of secrets to manage, keyed by short name; see the shape below | required |
| `name_prefix` | Put in front of every key to form the secret name; empty uses the key alone | `""` |
| `name_separator` | Single character joining prefix and key, one of `/ _ + = . @ -` | `"/"` |
| `recovery_window_in_days` | Default recovery window, 0 or 7 to 30; a secret may override | `0` |
| `kms_key_id` | Default KMS key id, alias or ARN; null uses `aws/secretsmanager` | `null` |
| `tags` | Tags on every secret, on top of the provider `default_tags` | `{}` |
| `json_generate_carry_enabled` | Plan time known switch for whether a kept `json_generate` entry is read back; false mints every kept entry fresh | `true` |
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

  json_generate = optional(map(object({
    format           = optional(string, "password") # password or bytes32-base64
    keep             = optional(bool, false)        # carry the live value through a version bump
    length           = optional(number, 32)
    special          = optional(bool, true)
    override_special = optional(string)
    min_special      = optional(number, 0)
    min_numeric      = optional(number, 0)
    min_upper        = optional(number, 0)
    min_lower        = optional(number, 0)
  })), {})
  json_preserve_unmanaged = optional(bool, false)   # keep live keys the blob does not declare

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

- A secret may set at most one of `generate`, `value`, the `json` shape and `placeholder`; setting two
  fails validation at plan time. `json`, `json_generate` and `json_preserve_unmanaged` make up the one
  shape that goes together, because each adds to the same blob rather than replacing it.
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
  ephemeral generator produces a fresh value on every run. Adding a `json_generate` entry to a secret
  that already has a version is the same edit: the new key is not minted until `version` is bumped in
  the same change, and until then the application reads a blob without it.
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
  blob change. A kept entry the current blob does not hold yet is minted fresh, so an existing secret
  can adopt `json_generate` with `keep = true` from the start. Leave `keep` false only for a brand new
  secret, because the read fails if the secret has no version at all. Rotating a kept entry on purpose
  means setting `keep = false` and bumping `version` in the same change.
- A kept entry's read back is the one thing a fresh account cannot plan. `keep = true` declares an
  ephemeral `aws_secretsmanager_secret_version` on the secret, and on a first apply the same run that
  creates the secret also reads it, so the read fails with `reading AWS Secrets Manager Secret
  Versions Data Source (<null>): couldn't find resource` once most of the estate already exists.
  Whether a version exists is not knowable at plan time, so it comes in as `json_generate_carry_enabled`,
  a literal boolean: pass `false` on the first apply in a fresh account and `true` from the second
  onwards, typically wired from the same switch that gates the function images, for example
  `bootstrap_image_tag != ""`. False mints every kept entry fresh, exactly as `keep = false` does,
  declares no ephemeral read at all, and still writes the version, so the estate lands in one apply
  rather than costing a second product commit to flip `keep`.
- Flipping `json_generate_carry_enabled` from `false` to `true` without bumping `version` plans no
  change and rewrites nothing. `secret_string_wo` is write-only, so Terraform never keeps the blob in
  state and cannot diff it: `secret_string_wo_version` is the only attribute that moves the resource.
  A plan with the switch flipped and `version` untouched shows the version resource unchanged, and the
  stored blob keeps the value the first apply minted. Bumping `version` in the same change is what
  republishes the blob, and from then on the kept entry is carried forward rather than reminted.
- The aws provider floor is `>= 6.50`, the release that stopped replacing a version when it switches
  between `secret_string` and `secret_string_wo` without the value changing. The random provider floor
  is `>= 3.9`, which is where the ephemeral `random_bytes` landed (the ephemeral `random_password`
  arrived in 3.7), and `required_version` is `>= 1.11`, which is where write-only arguments landed.
- A caller whose `.terraform.lock.hcl` pins random below 3.9 cannot reach that floor by bumping the
  module pin alone, and the run stalls in init rather than failing with a constraint error. Run
  `terraform init -upgrade` and commit the refreshed lock in the same change that adopts this version.
- Moving to `json_preserve_unmanaged` plans no change when `version` is left alone. Delete the `json`
  entries the operator will own, and the variables that fed them, add `json_preserve_unmanaged = true`,
  and keep `version` and any `json_generate` block exactly as they are. The version resource keeps its
  address (a secret without `json_generate` stays on `aws_secretsmanager_secret_version.this`, one with
  it stays on `.json_generate`), and `secret_id` does not move. The provider plans a write-only version
  only when `secret_string_wo_version` differs from state, since it never keeps `secret_string_wo` to
  compare, so the plan reads the two new data sources and changes nothing. The live blob keeps every
  key, and the next `version` bump writes those same keys back. The one exception is a version whose
  state still holds a plaintext `secret_string` from before the write-only adoption: the provider
  compares that against the new blob and replaces the version when they differ. Check first without
  printing the value, for example `terraform show -json | jq '[.values.root_module.child_modules[].resources[]
  | select(.type == "aws_secretsmanager_secret_version") | {address, legacy: ((.values.secret_string // "") != "")}]'`.
- An operator owns an undeclared key end to end. Set or change one with `put-secret-value` carrying
  the whole blob, every key included, because a put replaces the secret string rather than merging
  into it. Delete one the same way, by putting the blob without it. Terraform never removes a key it
  does not declare, and a declared `json` key wins over the live value of the same name on every write.
- The live value must be a JSON object. A blob an operator broke into anything else fails the next
  write at plan with a decode error rather than overwriting it.
- Preserving secrets need no fresh account switch. At plan the module lists the secret by name and
  its version ids, through `aws_secretsmanager_secrets` and `aws_secretsmanager_secret_versions`, and
  reads the live blob only when an `AWSCURRENT` version exists. A first apply writes the declared keys
  alone, and kept `json_generate` entries follow the same check, overriding
  `json_generate_carry_enabled`. The run role needs `secretsmanager:ListSecrets` and
  `secretsmanager:ListSecretVersionIds` on top of what it already has. A `depends_on` on the module
  call defers those lookups to apply and the first write then misses existing keys, so leave it off.
- Adding the first `json_generate` entry to a secret that only had `json` moves its version from
  `.this` to `.json_generate`, which replaces the version and rewrites the blob. With
  `json_preserve_unmanaged` on, the rewrite starts from the live keys, so nothing is lost.
