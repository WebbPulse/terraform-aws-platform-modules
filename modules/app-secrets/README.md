# terraform-aws-app-secrets

The application secrets of one estate: a set of AWS Secrets Manager secrets declared as a map,
each either generated here, passed in from a sensitive variable, composed into one JSON blob, or
seeded once as a placeholder for an operator to overwrite out of band. The module also hands back
a ready-made IAM policy granting read access to exactly those secrets, so the function that reads
them gets a grant that cannot drift away from what exists.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets`.
CarModPicker was carrying three secrets by hand in `terraform/secretsmanager.tf`; the module
reproduces them exactly, so adopting it is six `moved` blocks and an empty plan. See
[Adoption](#adoption). WebbPulse-Portfolio is on SSM SecureString parameters today and moves onto
this module as a separate change; see [Migrating from SSM SecureString](#migrating-from-ssm-securestring).

## How it works

```
var.secrets = {
  "secret-key" = { value = var.secret_key }          ─┐
  "sentry-dsn" = { }                                  │   aws_secretsmanager_secret.this[key]
  "app"        = { json = { ... } }                   ├──▶  name = "<name_prefix>/<key>"
  "session"    = { generate = true }                  │     recovery_window, kms_key_id, tags
  "admin-pw"   = { placeholder = "REPLACE_ME" }      ─┘
                                                            │
        random_password.this[key]  ─── generate ────────────┤
                                                            ▼
                       aws_secretsmanager_secret_version.this[key]          value owned by Terraform
                       aws_secretsmanager_secret_version.placeholder[key]   seeded once, ignore_changes
                       (neither)                                            populated entirely out of band

outputs.read_policy_json ──▶ aws_iam_role_policy on the function's role
                             Allow secretsmanager:GetSecretValue, DescribeSecret on those ARNs
```

### One secret, one of five shapes

| Field set | What Terraform stores | What an operator does |
| --- | --- | --- |
| `generate = true` | a `random_password` result, never read back | nothing |
| `value = "..."` | the string given, usually a sensitive variable | nothing |
| `json = { ... }` | `jsonencode` of the map, one blob for a cold-start read | nothing |
| `placeholder = "..."` | the literal, once, with `ignore_changes` on the value | `put-secret-value` sets the real one, and Terraform never plans it back |
| none of them | no version at all | the first `put-secret-value` creates version 1 |

An empty string in `value` counts as no value rather than as a version holding `""`. Secrets
Manager has no empty version, and the shape this serves is an optional secret wired to an optional
variable: the secret is created either way so the application's IAM grant is stable, and the
version appears only once the variable is set. `create_empty_version = true` overrides that for a
consumer that wants the version resource to exist regardless.

`json` drops entries whose value is null and keeps entries whose value is an empty string, because
an application that distinguishes "set to empty" from "absent" needs the key present. Terraform's
`jsonencode` sorts object keys, so the stored blob is stable across reorderings of the map.

Placeholder secrets live in their own resource rather than sharing one with the others:
`lifecycle.ignore_changes` takes a literal list, not an expression, so it cannot be switched per
instance of a single resource.

### The read policy

`read_policy_json` is one statement: `policy_actions` on the ARNs of the secrets named by
`policy_secret_keys`, defaulting to every secret the module manages. Attach it directly:

```hcl
resource "aws_iam_role_policy" "api_secrets" {
  name   = "app-secrets"
  role   = aws_iam_role.api.id
  policy = module.app_secrets.read_policy_json
}
```

A consumer that already builds one inline policy out of several statements takes
`read_policy_statement` instead and merges it in, or takes `policy_resources` and writes the
statement itself.

Like the `github-actions-role` module, the rendering follows the one-or-many convention IAM
accepts and hand-written policies usually use: a field holding exactly one entry renders as a bare
JSON string, several as a list. That keeps a policy that replaces a hand-written one byte-identical
in state rather than merely equivalent.

### Secret material and this module

Nothing here reads a secret value back out of AWS. `random_password` results and the values passed
in through `value`, `json` and `placeholder` land in Terraform state, which is where a
Terraform-managed secret has always lived, and no output exposes any of them. `has_version` calls
`nonsensitive()` on a boolean, not on a value: `for_each` keys cannot be derived from a sensitive
value, and whether a secret has a value at all is a fact about the configuration rather than about
the secret. No secret material reaches a resource key, an output or the plan text through it.

A value Terraform must not learn belongs in the `placeholder` shape, or in a secret with no value
at all.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `secrets` | Map of secrets to manage, keyed by short name. See the table below | required |
| `name_prefix` | Put in front of every key to form the secret name, for example `carmodpicker-staging` | `""` |
| `name_separator` | Character joining prefix and key | `/` |
| `recovery_window_in_days` | Default recovery window; `0` or 7 to 30 | `0` |
| `kms_key_id` | Default KMS key; null uses `aws/secretsmanager` | `null` |
| `description_default` | Description for secrets that set none | `null` |
| `tags` | Tags on every secret, on top of `default_tags` | `{}` |
| `create_empty_version` | Give a secret with no value an empty version resource anyway | `false` |
| `policy_actions` | Actions in the generated read policy | `["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]` |
| `policy_secret_keys` | Keys the read policy covers; null means all of them | `null` |
| `policy_sid` | Sid on the policy statement; null renders no Sid | `null` |

Per-secret fields inside `secrets`:

| Field | Description | Default |
| --- | --- | --- |
| `name` | Full secret name, overriding `name_prefix` plus key | key behind the prefix |
| `description` | Description shown in the console | `description_default` |
| `generate` | Generate the value with `random_password` | `false` |
| `generate_length` | Length, 8 to 512 | `32` |
| `generate_special` | Allow special characters | `true` |
| `generate_override_special` | Exact set of special characters allowed | `null` |
| `generate_min_special`, `generate_min_numeric`, `generate_min_upper`, `generate_min_lower` | Character-class floors | `0` |
| `value` | Value passed in; empty string means no version | `null` |
| `json` | Map composed into one JSON object | `null` |
| `placeholder` | Literal seeded once, then `ignore_changes` on the value | `null` |
| `recovery_window_in_days` | Overrides the module default | module default |
| `kms_key_id` | Overrides the module default | module default |
| `tags` | Merged over the module-wide tags | `{}` |

The `generate_*` defaults match the provider's own defaults for `random_password`, so an existing
`random_password` resource can be moved into the module without the generator's arguments changing
and the value being regenerated.

## Outputs

| Name | Description |
| --- | --- |
| `arns` | Secret ARN per key. Pass one to an application as `APP_SECRETS_ARN` or similar |
| `names` | Full secret name per key, the `--secret-id` for `put-secret-value` |
| `ids` | Secret id per key, for a consumer that referenced `.id` on the hand-written resource |
| `version_ids` | Version id of each Terraform-managed version, for ordering only |
| `read_policy_json` | Policy document granting `policy_actions` on the covered secrets |
| `read_policy_statement` | The same statement as an object, for composing one policy from several |
| `policy_resources` | The covered ARNs, sorted |

## Adoption

The module ships from 1.6.0, so consumers pin `version = "~> 1.6"`. Land it on `staging` first and
read the speculative plan: it must show only the moves, `0 to add, 0 to change, 0 to destroy`.

### CarModPicker

Replace the contents of `terraform/secretsmanager.tf`:

```hcl
module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 1.6"

  name_prefix = local.prefix

  secrets = {
    "secret-key" = {
      description = "JWT signing key for the FastAPI backend"
      value       = var.secret_key
    }

    # Sentry DSN (Phase 2 / OBS-01).
    # Created empty by `terraform apply`; operator populates the value out-of-band
    # with `aws secretsmanager put-secret-value` after creating the Sentry project
    # manually per D-55 / terraform README "Bootstrap: Sentry".
    "sentry-dsn" = {
      description = "Sentry DSN for backend error reporting (Sentry project created manually per D-54). Populated via put-secret-value post-apply."
      value       = var.sentry_dsn
    }

    "app" = {
      description = "JSON map of runtime secrets read by the Lambda API at cold start"
      json = {
        SECRET_KEY = var.secret_key
        SENTRY_DSN = var.sentry_dsn
      }
    }
  }
}

moved {
  from = aws_secretsmanager_secret.secret_key
  to   = module.app_secrets.aws_secretsmanager_secret.this["secret-key"]
}

moved {
  from = aws_secretsmanager_secret_version.secret_key
  to   = module.app_secrets.aws_secretsmanager_secret_version.this["secret-key"]
}

moved {
  from = aws_secretsmanager_secret.sentry_dsn
  to   = module.app_secrets.aws_secretsmanager_secret.this["sentry-dsn"]
}

moved {
  from = aws_secretsmanager_secret_version.sentry_dsn[0]
  to   = module.app_secrets.aws_secretsmanager_secret_version.this["sentry-dsn"]
}

moved {
  from = aws_secretsmanager_secret.app
  to   = module.app_secrets.aws_secretsmanager_secret.this["app"]
}

moved {
  from = aws_secretsmanager_secret_version.app
  to   = module.app_secrets.aws_secretsmanager_secret_version.this["app"]
}
```

The file's own `moved` block from `aws_secretsmanager_secret_version.sentry_dsn` to
`...sentry_dsn[0]` goes away, replaced by the `[0]` source above: Terraform follows a chain of
moves, and staging has no version for that secret today because `var.sentry_dsn` is empty there,
so the block is inert in staging and moves the real version in production.

In `terraform/lambda.tf`, two references change to the module's output. Keep the statement inside
`data.aws_iam_policy_document.lambda_api_runtime` where it is rather than replacing it with
`read_policy_json`: that document renders three statements in a fixed order and the module's policy
is a separate document, so swapping it in would rewrite the inline policy. Only the ARN moves:

```hcl
data "aws_iam_policy_document" "lambda_api_runtime" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.app_secrets.arns["app"]]
  }
  ...
}

locals {
  lambda_environment = { for key, value in {
    ...
    APP_SECRETS_ARN = module.app_secrets.arns["app"]
    ...
  } : key => value if value != "" }
}
```

An estate whose secrets grant stands on its own can instead attach `read_policy_json` with
`policy_secret_keys = ["app"]` and `policy_actions = ["secretsmanager:GetSecretValue"]`, which is
the same permission in a policy the module owns. That is a one-line change to the inline policy
document, so it is a separate commit, not part of the zero-diff move.

Verified against `CarModPicker-staging`: `Plan: 0 to add, 0 to change, 0 to destroy`, five `moved`
notices and nothing else.

### WebbPulse-Portfolio

Portfolio stores the same class of values in SSM SecureString parameters today, so adopting this
module is a migration rather than a move. See the next section. Once the values are across, the
`terraform/db.tf` contents become:

```hcl
module "app_secrets" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-secrets"
  version = "~> 1.6"

  name_prefix = local.prefix

  secrets = {
    "secret-key" = {
      generate        = true
      generate_length = 64
    }

    # Admin credentials seeded into the app on startup. Set values manually in
    # Secrets Manager after first apply; Terraform ignores subsequent changes.
    "admin-username" = { placeholder = "REPLACE_ME" }
    "admin-password" = { placeholder = "REPLACE_ME" }
    "admin-email"    = { placeholder = "REPLACE_ME" }
  }
}

moved {
  from = random_password.secret_key
  to   = module.app_secrets.random_password.this["secret-key"]
}
```

The `moved` block on `random_password.secret_key` is the load-bearing one: without it Terraform
destroys the generator and creates a new one, which regenerates the signing key and invalidates
every live session. The four `aws_ssm_parameter` resources have no counterpart to move to, so they
are removed once the values are copied into Secrets Manager, and the application's environment
variable is repointed at the new ARNs first.

Verified against `WebbPulse-Portfolio-staging`: `Plan: 8 to add, 0 to change, 4 to destroy`, and
the move notice on `random_password` reads `12 unchanged attributes`, so the generator carries its
existing value into the module rather than producing a new one. The adds are the four secrets and
their four versions; the destroys are the four SSM parameters. That is the migration, not a move,
which is why Portfolio does it as its own change in the order set out below rather than in one
apply.

## Migrating from SSM SecureString

The move from an SSM SecureString parameter to a Secrets Manager secret copies a value without
that value ever appearing in a terminal, a log, a plan or an agent transcript. Four steps, in this
order, so the application is never pointed at a secret that has no value yet.

**1. Create the secret through the module as a placeholder.** Add the entry with
`placeholder = "REPLACE_ME"` and apply. The secret now exists with a throwaway version, its ARN is
stable, and `ignore_changes` means Terraform will not plan over whatever lands there next.

**2. Copy the value with a pipeline that never prints it.** One command, no intermediate file, no
value on stdout:

```sh
aws ssm get-parameter \
      --name /webbpulse-production/admin-password \
      --with-decryption \
      --query Parameter.Value \
      --output text \
  | aws secretsmanager put-secret-value \
      --secret-id webbpulse-production/admin-password \
      --secret-string file:///dev/stdin \
      --query VersionId \
      --output text
```

`--query VersionId` keeps the response from echoing the secret back. Confirm the copy by comparing
lengths rather than contents if you need to check it at all:

```sh
test "$(aws secretsmanager get-secret-value --secret-id webbpulse-production/admin-password \
          --query 'length(SecretString)' --output text)" \
   = "$(aws ssm get-parameter --name /webbpulse-production/admin-password --with-decryption \
          --query 'length(Parameter.Value)' --output text)" && echo match
```

A generated value that the application does not need continuity on is simpler still: skip the copy,
declare the secret with `generate = true`, and let Terraform create a fresh one. A signing key is
usually not in that category, because rotating it logs everyone out.

**3. Switch the application's environment variable and its IAM grant.** Point the function at
`module.app_secrets.arns["..."]`, attach `read_policy_json`, drop the `ssm:GetParameter` grant, and
deploy. Read the new secret in the application before removing anything, so a rollback is a
redeploy rather than a restore.

**4. Delete the parameter.** Remove the `aws_ssm_parameter` resource from the configuration and
apply, which deletes it. Keep it for one deploy cycle if a rollback is still plausible.

Never paste a value between the two commands, never write it to a file the shell keeps, and never
run `get-parameter --with-decryption` or `get-secret-value` in a way that puts the value on a
terminal that is being recorded.

## Known limits

- No rotation. `aws_secretsmanager_secret_rotation`, a rotation Lambda and a rotation schedule are
  outside this module; a secret that rotates is a different lifecycle and belongs next to the
  function that rotates it.
- No resource policy on the secret. Cross-account reads need `aws_secretsmanager_secret_policy`
  attached from outside using the `names` output.
- No replication to other regions.
- One read policy per module instance. A second role that reads a different subset takes
  `policy_resources` and writes its own statement, or a second instance of the module manages its
  own secrets.
- Renaming a key renames the secret, which replaces it. Set `name` explicitly to change the map key
  without touching the secret.
