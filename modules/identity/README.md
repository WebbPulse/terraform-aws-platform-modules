# terraform-aws-identity

A product's whole identity layer as one module block: the KMS signing keys the access tokens are
signed with, the symmetric KMS key TOTP seeds are sealed under, the six DynamoDB tables the identity
flows read and write, the three IAM grants that let the identity function reach all of them, and
optionally the API Gateway JWT authorizer that verifies the resulting tokens at the edge.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/identity`.

The module implements the shared identity standard, and its defaults are the standard's decisions
rather than this module's preferences. The table key schemas in particular are
`webbpulse.identity`'s contract: `storage.py` and `lockout.py` write these exact attribute names,
and a table whose hash key does not match what the store writes applies cleanly and then fails on
the login path at request time. Changing a key in the default `tables` map is changing the
package's storage layer.

Portfolio carries hand-written KMS resources in `terraform/identity.tf` from milestone M1; the
module reproduces them exactly, so adopting it is three `moved` blocks and an empty plan. The
tables and the authorizer are new. See [Adoption](#adoption).

## How it works

```
signing_key_count + active_signing_key
   │
   ▼
aws_kms_key.identity_signing[0..n]          RSA_2048, SIGN_VERIFY, rotation off
   ├─ aws_kms_alias.identity_signing[0]  ──▶ alias/<name_prefix>-identity-signing
   │                                         targets the active signer
   └─ ordered by active_signing_key
      ▼
   signing_key_arns = [active, then the rest in index order]
      │                 head signs; every element is published in the JWKS
      ▼
   identity_environment.IDENTITY_SIGNING_KEY_ARNS  (a JSON array)

var.tables = { <key> = { attributes, hash_key, range_key?, global_secondary_indexes?,
                         ttl_attribute?, point_in_time_recovery?, deletion_protection? } }
   │  name = "${var.name_prefix}-${key}"
   ▼
aws_dynamodb_table.this[<key>]      credentials, refresh-tokens, identity-tokens, login-attempts,
   ▼                                  totp-factors, recovery-codes
outputs: table_names, table_arns, table_arns_list, tables

enable_mfa_encryption_key (default true)
   │
   ▼
aws_kms_key.identity_mfa            SYMMETRIC_DEFAULT, ENCRYPT_DECRYPT, rotation ON
   ├─ aws_kms_alias.identity_mfa ──▶ alias/<name_prefix>-identity-mfa
   ▼
   identity_environment.IDENTITY_DATA_KEY_ARN

identity_role_name
   ├─ aws_iam_role_policy.identity_signing   kms:Sign + kms:GetPublicKey on every signing key
   ├─ aws_iam_role_policy.identity_tables    item level access to every table and index
   └─ aws_iam_role_policy.identity_mfa       kms:GenerateDataKey + kms:Decrypt on the envelope key,
                                             conditioned on the encryption context purpose

http_api_id (optional)
   └─ terraform_data.discovery_document_ready ──▶ aws_apigatewayv2_authorizer.identity_jwt
                                                   issuer + audience, RS256
                                                   ▼
                                                 authorizer_id, for the caller to attach to routes
```

- **The signing key list is ordered, and the order is the design.** `signing_key_arns` puts the
  active key first and never sorts. The package signs with `signing_key_arns[0]` and publishes the
  public half of every entry in the JWKS, so the list is behaviour rather than presentation. A
  rotation is two applies: raise `signing_key_count` and deploy, so the JWKS serves both keys while
  the old one still signs, then move `active_signing_key` to the new index and deploy. Promoting in
  the same apply that creates the key signs with a key no verifier has fetched yet.
- **Automatic KMS rotation is off deliberately.** The `kid` a verifier matches on is the base64url
  SHA-256 of the DER SubjectPublicKeyInfo, which makes it a function of the key material. Rotating
  material behind one key id changes what `GetPublicKey` returns, the derived `kid` follows it, and
  every already-issued token then references a `kid` the JWKS no longer serves. Rotation here is by
  adding a key, never by mutating one.
- **The envelope key rotates automatically and the signing keys do not, for the same reason.** The
  reason is the `kid`. A signing key's identifier is derived from its material, so rotating it
  orphans every already-issued token. An envelope key has no such identifier: KMS keeps every
  previous backing key and picks the right one out of the wrapped blob, so a data key wrapped last
  year still opens after a rotation with nothing to re-encrypt and no user to re-enrol. Rotation
  there is free, which is why it is on.
- **A TOTP seed is the one identity secret that cannot be hashed**, which is why it gets a key of
  its own. The server has to reproduce the code to check it, so unlike a password there is no
  one-way form and unlike a passkey there is no public half: a read of `totp-factors` is a complete
  compromise of the second factor for every user in it. DynamoDB's own encryption at rest is under
  an AWS owned key and is transparent to any principal that can call `Query`. Sealing the seed under
  a separate key means a usable seed needs `dynamodb:GetItem` **and** `kms:Decrypt` with the right
  encryption context, and every decrypt is a CloudTrail event. It is a different key from the
  signing key deliberately: one key that could both sign tokens and open seeds would make the blast
  radius of either compromise the whole of both.
- **The grant is `GenerateDataKey` and `Decrypt`, never `Encrypt`.** The package uses envelope
  encryption, so KMS mints a fresh 256-bit data key per seed, AES-256-GCM happens locally, and only
  the wrapped key is ever sent to KMS. A plaintext seed never reaches KMS, so `kms:Encrypt` would
  widen the grant for a call nothing makes. A fresh data key per secret is also what makes GCM
  nonce reuse impossible by construction rather than by a counter somebody has to maintain.
- **Only the `purpose` half of the encryption context can be pinned in IAM.** The package sends
  `{"user_id": "<id>", "purpose": "totp"}` on both calls, and KMS binds it into the wrapped key as
  authenticated additional data, which is what makes a ciphertext copied into another user's row
  fail to decrypt. In a policy condition only `purpose` has a fixed value: `user_id` differs per
  user and no static condition can name it. Pinning `purpose` still buys the real property, that
  this key is usable for TOTP seeds and nothing else, so a later feature wanting an envelope gets
  its own key rather than quietly widening this one.
- **Per-entity tables, not single table.** TTL is a table-level setting. Refresh tokens and
  verification tokens want one and credentials must never have one, so mixing them would leave the
  permanent items carrying a TTL attribute that must never be set, where one bug deletes accounts.
  Separate tables make that failure impossible rather than merely unlikely. Per-table IAM is the
  other half.
- **The three identity strings are close to irreversible.** The `issuer` is byte identical in three
  places (the `iss` claim, the discovery document's `issuer` member, the authorizer's configured
  issuer) and a mismatch denies every request while logging no reason. The `audience` carries the
  environment so a staging token is not accepted by production. The `registrable_domain` is hashed
  into every passkey by the authenticator and is immutable for that credential's life.
- **The alias closes a dependency loop with a string.** The key policy names the identity
  function's role, so the key depends on the Lambda. Naming the key from inside that module's
  environment would make the module depend on the key and Terraform would refuse the graph. The
  alias name is a pure function of `name_prefix`, and KMS accepts an alias anywhere it accepts a
  key id for `Sign` and `GetPublicKey`.
- **Validation catches at plan time what DynamoDB and KMS reject at apply time.** Every hash and
  index key must name a declared attribute, `signing_key_count` is one to four, `active_signing_key`
  must index a key that exists, the key spec must be RSA, and the issuer must be `https` with no
  trailing slash.

## Ordering, and why the authorizer is usually a second apply

`CreateAuthorizer` on an HTTP API validates the issuer **synchronously**. API Gateway fetches
`<issuer>/.well-known/openid-configuration` during the create call and rejects it with

```
BadRequestException: ... Issuer must have a valid discovery endpoint ended with
'/.well-known/openid-configuration'
```

when it does not get a discovery document back. This is not documented; it was learned from a
failed apply on Portfolio's M0 spike. Two things must therefore already be true when the authorizer
is created, and neither is implied by anything it references:

1. The identity function is serving the discovery document and the JWKS.
2. The two `.well-known` routes exist on the API and answer **anonymously**. They cannot sit behind
   an authorizer of any kind, because API Gateway's own validator fetches them from outside with no
   credentials of ours. On an API fronted by the staging access gate that means
   `authorization_type = "NONE"` on exactly those two routes.

So on the first apply of a new environment, leave `http_api_id` null. Once the function is deployed
and the routes answer, set it along with `authorizer_depends_on`.

`depends_on` orders Terraform's API calls and not their effects, which is the gap
`wait_for_discovery_document` closes. Three separate lags sit between "CreateRoute returned 201" and
"a request from API Gateway's validator gets a document back": an `auto_deploy` stage deploys a new
route asynchronously, `UpdateFunctionConfiguration` returns while `LastUpdateStatus` is still
`InProgress`, and a container image function under the Lambda Web Adapter takes seconds to cold
start. Any one of them makes `CreateAuthorizer` fetch a 404, and the failure is the same
`BadRequestException` as having no route at all, with nothing to say which of the two it was. The
module polls the real URL until it answers, so a spurious failure and a real misconfiguration stop
being indistinguishable.

**Protected routes are not created here, deliberately.** A route naming this authorizer must be
created after it, while the discovery routes must be created before it. Putting both in one
`for_each` collapses the two orderings into one and Terraform refuses the graph. The module hands
back `authorizer_id` and the consumer attaches it, either through the `http-api` module's per-route
`authorizer_id` or on a standalone `aws_apigatewayv2_route`.

## The MFA routes, and the one that must stay in front of the authorizer

`webbpulse` 0.12.0 mounts six MFA routes under the issuer's path. They mount only when TOTP is
enabled and the product supplies the two M4 stores, which is what the `totp-factors` and
`recovery-codes` tables above are for. The module does not create routes, so this is a table of what
the consumer attaches `authorizer_id` to and what it must not.

| Route | Behind the JWT authorizer |
| --- | --- |
| `POST <issuer>/login/totp` | **No.** See below. |
| `POST <issuer>/totp/enrol` | Yes |
| `POST <issuer>/totp/activate` | Yes |
| `POST <issuer>/totp/disable` | Yes |
| `POST <issuer>/recovery-codes` | Yes |
| `POST <issuer>/step-up` | Yes |

**`login/totp` must not be behind the authorizer, and the reason is the audience.** It is the second
leg of an MFA login: the caller has proved a password and holds an MFA ticket, not an access token.
The ticket is deliberately minted with an audience of `<issuer>/mfa` rather than the API's audience,
which is exactly what stops it being spent anywhere else. The gateway's JWT authorizer is configured
with the API's `audience`, so a ticket presented to any route behind it is rejected before it
reaches any code of ours. Put `login/totp` behind the authorizer and every MFA login fails at its
second step, with a gateway 401 that names no reason and never reaches a log of the function's.

Give it `authorization_type = "NONE"`, the same treatment the two `.well-known` routes get, and for
a related reason: in all three cases the caller cannot yet hold the credential the authorizer wants.

The other five do sit behind it, and it is worth saying why that is safe rather than merely
conventional. Each one acts on an already-authenticated user and reads its subject from the
**verified claims** rather than from the request body. A user id in the body would let anybody enrol
a factor on anybody else's account, so the authorizer is not decoration on these routes: it is where
the subject comes from.

## Usage

```hcl
module "identity" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/identity"
  version = "~> 2.6"

  name_prefix        = local.prefix
  issuer             = "https://${local.api_host}/api/auth"
  audience           = "${local.prefix}-api"
  registrable_domain = local.registrable_domain

  identity_role_name = module.lambda_domain["identity"].role_id
  identity_role_arn  = module.lambda_domain["identity"].role_arn

  point_in_time_recovery = true
  deletion_protection    = var.environment == "production"
}
```

A fuller worked example, including the environment block and the authorizer wiring, is in
[`examples/identity-basic`](../../examples/identity-basic).

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name_prefix` | `string` | required | Prefix for every name the module builds. `webbpulse-staging` gives `alias/webbpulse-staging-identity-signing` and `webbpulse-staging-credentials`. Must match the application's table prefix. |
| `issuer` | `string` | required | The issuer, byte for byte, carrying the `/api/auth` path. `https`, no trailing slash. |
| `audience` | `string` | required | The `aud` claim the function stamps and the authorizer requires. |
| `registrable_domain` | `string` | required | Registrable domain for the refresh cookie and the WebAuthn RP ID. A bare domain, not a URL. |
| `identity_role_name` | `string` | `null` | Role name to attach the signing and table policies to. `null` attaches nothing. |
| `identity_role_arn` | `string` | `null` | Role ARN named as a principal in the KMS key policy. Separate from the name because a key policy takes an ARN. |
| `signing_key_count` | `number` | `1` | How many signing keys exist, 1 to 4. |
| `active_signing_key` | `number` | `0` | Zero-based index of the key that signs. Decides the order of `signing_key_arns`. |
| `signing_key_spec` | `string` | `"RSA_2048"` | RSA only: the JWT authorizer verifies RSA signatures. |
| `signing_key_deletion_window_in_days` | `number` | `30` | Waiting period before KMS deletes a removed key. |
| `signing_key_policy_json` | `string` | `null` | Replaces the generated key policy outright. A replacement still needs an account root statement. |
| `create_signing_key_alias` | `bool` | `true` | Create `alias/<name_prefix>-identity-signing` pointing at the active signer. |
| `enable_mfa_encryption_key` | `bool` | `true` | Create the symmetric KMS key TOTP seeds are sealed under, and grant the identity role `GenerateDataKey` and `Decrypt` on it. |
| `mfa_encryption_key_arn` | `string` | `null` | An existing symmetric key to use instead. Set with `enable_mfa_encryption_key = false`. Granted and exported exactly as a created key is. |
| `mfa_encryption_key_deletion_window_in_days` | `number` | `30` | Waiting period before KMS deletes the envelope key. Deleting it makes every stored seed permanently unreadable. |
| `mfa_encryption_key_rotation` | `bool` | `true` | Automatic annual rotation on the envelope key. On, unlike the signing keys: KMS keeps previous backing keys, so a data key wrapped before a rotation still opens. |
| `create_mfa_encryption_key_alias` | `bool` | `true` | Create `alias/<name_prefix>-identity-mfa`. |
| `mfa_encryption_key_policy_json` | `string` | `null` | Replaces the generated envelope key policy outright. A replacement still needs an account root statement. |
| `mfa_encryption_context_purpose` | `string` | `"totp"` | Value pinned in both halves of the grant as `StringEquals` on `kms:EncryptionContext:purpose`. `null` omits the condition. |
| `tables` | `map(object)` | the six identity tables | Tables to create, keyed by the logical name the package uses. `{}` creates none. |
| `point_in_time_recovery` | `bool` | `true` | Module-wide default for continuous backups. |
| `deletion_protection` | `bool` | `false` | Module-wide default for the DynamoDB deletion protection flag. |
| `billing_mode` | `string` | `"PAY_PER_REQUEST"` | `PAY_PER_REQUEST` or `PROVISIONED`. |
| `server_side_encryption` | `object` | `null` | Encrypt tables with a customer managed key instead of the AWS owned one. |
| `table_policy_actions` | `list(string)` | item level actions | DynamoDB actions the table grant allows. No `Scan` by default. |
| `name_tag` | `bool` | `false` | Add a `Name` tag equal to each table's full name. |
| `tags` | `map(string)` | `{}` | Tags for every resource the module creates. |
| `http_api_id` | `string` | `null` | HTTP API to create the JWT authorizer on. Leave null until the discovery document answers. |
| `authorizer_name` | `string` | `null` | Defaults to `<name_prefix>-identity-jwt`. |
| `authorizer_identity_sources` | `list(string)` | `["$request.header.Authorization"]` | Where the authorizer reads the token from. |
| `authorizer_audiences` | `list(string)` | `null` | Replaces the single-audience default when more than one is needed. |
| `authorizer_depends_on` | `any` | `[]` | What must already exist and answer before the authorizer is created. Usually `[module.api, module.lambda_domain]`. |
| `wait_for_discovery_document` | `bool` | `true` | Poll the discovery URL and refuse to create the authorizer until it answers. Needs `curl` and network reach. |
| `discovery_document_attempts` | `number` | `60` | One second attempts before the poll fails the apply. |

## Outputs

| Name | Description |
| --- | --- |
| `signing_key_arns` | The signing keys, active signer first. This is `IDENTITY_SIGNING_KEY_ARNS`. |
| `active_signing_key_arn` | The key that signs today, which is `signing_key_arns[0]`. |
| `signing_key_ids` | Key id of each key, in creation index order rather than signing order. |
| `signing_key_alias` | `alias/<name_prefix>-identity-signing`, or null when the alias is off. |
| `signing_key_alias_arn` | ARN of the alias, null when not created. |
| `signing_policy_json` | The signing grant as a policy document, for a consumer attaching it by hand. |
| `mfa_encryption_key_arn` | The key TOTP seeds are sealed under, which is `IDENTITY_DATA_KEY_ARN`. Null when there is none. |
| `mfa_encryption_key_id` | Key id of the envelope key, null when the module did not create one. |
| `mfa_encryption_key_alias` | `alias/<name_prefix>-identity-mfa`, or null when the key or the alias is off. |
| `mfa_encryption_key_alias_arn` | ARN of the envelope key alias, null when not created. Not usable as an IAM policy resource. |
| `mfa_policy_json` | The envelope grant as a policy document, null when there is no key. |
| `table_names` | Logical key to full table name. The map an application passes to its Lambda. |
| `table_arns` | Logical key to table ARN. |
| `table_arns_list` | Every table ARN as a list, sorted by key. |
| `tables` | Logical key to `{ name, arn, id }`. |
| `table_policy_json` | The table grant as a policy document, including the index wildcard. |
| `authorizer_id` | Id of the JWT authorizer, null when `http_api_id` was not given. Attach it to protected routes. |
| `authorizer_name` | Name of the authorizer, null when not created. |
| `identity_environment` | The `IDENTITY_*` variables that follow from this module's own resources. |
| `issuer` | The issuer, echoed back. |
| `audience` | The audience, echoed back. |

## Adoption

Portfolio's `terraform/identity.tf` carries the M1 KMS resources: the key, the alias and the
signing role policy. Those three move into the module with no change to what exists in AWS. The
four tables and the JWT authorizer do **not** exist yet at `origin/staging`, so those are ordinary
creates rather than moves.

The module's resources use `count`, so each destination address carries `[0]`.

```hcl
module "identity" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/identity"
  version = "~> 2.6"

  name_prefix        = local.prefix
  issuer             = local.identity_issuer
  audience           = local.identity_audience
  registrable_domain = local.registrable_domain

  identity_role_name = module.lambda_domain["identity"].role_id
  identity_role_arn  = module.lambda_domain["identity"].role_arn

  # Reproduces the tags the hand-written key carries, so the move is a no-op.
  tags = {
    Component = "identity"
    Milestone = "M1"
  }
  name_tag = true

  point_in_time_recovery = true
  deletion_protection    = var.environment == "production"
}

moved {
  from = aws_kms_key.identity_signing
  to   = module.identity.aws_kms_key.identity_signing[0]
}

moved {
  from = aws_kms_alias.identity_signing
  to   = module.identity.aws_kms_alias.identity_signing[0]
}

moved {
  from = aws_iam_role_policy.identity_signing
  to   = module.identity.aws_iam_role_policy.identity_signing[0]
}
```

The existing outputs are repointed at the module:

```hcl
output "identity_signing_key_alias" {
  value = module.identity.signing_key_alias
}
```

and the identity function's environment merges the module's map last, so it wins over the product
strings around it:

```hcl
environment = merge(
  {
    IDENTITY_ENVIRONMENT       = var.environment
    IDENTITY_PRODUCT_NAME      = "WebbPulse"
    IDENTITY_RP_NAME           = "WebbPulse"
    IDENTITY_SUPPORT_EMAIL     = "support@webbpulse.com"
    IDENTITY_FRONTEND_BASE_URL = local.frontend_base_url
    IDENTITY_TABLE_NAMES       = jsonencode(module.identity.table_names)
  },
  module.identity.identity_environment,
)
```

Land it on `staging` first and read the speculative plan. It must show the three moves, the four
tables as adds, and **no destroys**. A destroy on the KMS key means an address did not line up, and
that is the one mistake in this design with no recovery: fix the `moved` block rather than applying.

Because the KMS key description differs slightly from the hand-written one, expect an in-place
update on the key's description. It is metadata only and does not touch key material.

## Tests

`tests/signing_keys.tftest.hcl` pins the rotation contract: that the active key leads the list, that
the rest keep index order, that the list is never sorted, and that the validations refuse a fifth
key, an out-of-range active index, an ECC spec and a malformed issuer.

`tests/tables.tftest.hcl` pins the key schemas against the package's constants, including the
hyphenated logical names, the `family_id-generation-index` GSI name that `storage.py` names as a
literal, the `expires_at` TTL attributes, that the credentials table has no TTL at all, and that
neither M4 table has a TTL or an index.

`tests/mfa_encryption_key.tftest.hcl` covers the envelope key both ways: created by default with the
right spec, usage and rotation, turned off entirely with no key, no alias, no grant and no
environment variable, and supplied from outside, where the grant and the environment variable follow
the supplied ARN. It also pins the encryption context condition, including that the operator is
`StringEquals` rather than a set operator.

`tests/authorizer_and_grants.tftest.hcl` covers the authorizer arguments, the three IAM grants and
the environment map.

Every run is `command = plan` against a mocked provider, so the suite reaches no AWS API and needs
no credentials. The two data sources the KMS key policy depends on are supplied with `override_data`
for the same reason.

## Known limits

- **The tests cannot reach the failure that actually bites.** They are plan only, so they check the
  arguments Terraform will send to `CreateAuthorizer` and not whether the call succeeds. The
  synchronous discovery fetch is only exercised by a real apply.
- **The discovery poll needs `curl` and network reach** from wherever Terraform runs. It is present
  on the HCP Terraform worker image. A consumer running elsewhere sets
  `wait_for_discovery_document = false` and owns the ordering itself.
- **`moved` blocks cannot cross a module boundary from inside**, so the consumer writes them. That
  is why the adoption section above lives here rather than being expressed in the module.
- **Lowering `signing_key_count` schedules a key for deletion.** The deletion window is the last
  chance to notice that an already-issued token still references it. Never lower it in the same
  change that raises it.
- **No alarms.** Table and key monitoring belong to the estate's aggregate alarms rather than to
  per-table alarms created here. That includes the envelope key: a `Decrypt` on it is worth
  alarming on at the estate level rather than from this module.
- **The encryption context condition pins `purpose` only.** `user_id` is the half that stops a
  ciphertext being moved between rows, and KMS enforces it as authenticated additional data on
  every call, but it is a different value per user so no static IAM condition can express it. The
  policy therefore constrains what this key may be used *for*, not which user's seed a given call
  may open.
- **Deleting the envelope key is unrecoverable in a way the signing keys are not.** A lost signing
  key costs every user one extra login. A lost envelope key makes every stored TOTP seed
  permanently unreadable, and the only way back is every enrolled user re-enrolling.
- **One authorizer per module instance.** A product needing several authorizers on the same API
  creates the extra ones itself from `issuer` and `audience`.
