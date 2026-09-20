# terraform-aws-identity

A product's identity layer as one module block: the KMS RSA signing keys access tokens are signed
with, the symmetric KMS key TOTP seeds are sealed under, the ten identity DynamoDB tables plus the
opt in OAuth 2.1 authorization server, API key and share token tables, the IAM grants that reach
them, an
optional API Gateway JWT authorizer, and the `IDENTITY_*` environment map. It exists so a consumer wires `webbpulse.identity` with one module call instead of rebuilding
key names, table schemas and grants by hand.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/identity`.

## Usage

```hcl
module "identity" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/identity"
  version = "~> 2.6"

  name_prefix        = local.prefix
  issuer             = "https://${local.api_host}/api/auth"
  audience           = "${local.prefix}-api"
  registrable_domain = local.registrable_domain

  identity_role_name   = module.lambda_domain["identity"].role_id
  identity_role_arn    = module.lambda_domain["identity"].role_arn
  attach_role_policies = true

  deletion_protection = var.environment == "production"
}
```

The ten default tables and their key schemas, which are the `webbpulse.identity` package's
contract rather than this module's preference:

| Logical key | Hash key | Range key | Index | TTL |
| --- | --- | --- | --- | --- |
| `credentials` | `user_id` | `credential_type` | | |
| `refresh-tokens` | `token_hash` | | `family_id-generation-index`, `user_id-family_id-index` | `expires_at` |
| `identity-tokens` | `token_hash` | | | `expires_at` |
| `login-attempts` | `identity_key` | `attempted_at` | | `expires_at` |
| `totp-factors` | `user_id` | | | |
| `recovery-codes` | `user_id` | `code_hash` | | |
| `passkeys` | `user_id` | `credential_id` | `credential_id-index` | |
| `webauthn-challenges` | `challenge_id` | | | `expires_at` |
| `oauth-states` | `state` | | | `expires_at` |
| `oauth-links` | `provider_subject` | | `user_id-index` | |

Three further groups of tables are opt in, so an existing consumer's plan stays empty until it
asks for them.

`oauth_server_enabled = true` adds the three tables the OAuth 2.1 authorization server in
`webbpulse.identity.oauth_server` reads and writes, which is what a product turns on to host a
remote MCP server. These are not the social login tables above: `oauth-states` and `oauth-links`
are the sign-in side, where the package is an OAuth *client* against Google and GitHub, while
these three are the server side, where the package issues its own codes.

| Logical key | Hash key | Index | TTL |
| --- | --- | --- | --- |
| `oauth-clients` | `client_id` | | `expires_at` |
| `authorization-codes` | `code_hash` | | `expires_at` |
| `oauth-consents` | `consent_id` | `user_id-index` | none, deliberately |

`api_keys_table_enabled = true` adds the table `webbpulse.identity.api_keys` mints `wpk_` keys
into, for agents and scripts that are not a browser session.

| Logical key | Hash key | Index | TTL |
| --- | --- | --- | --- |
| `api-keys` | `key_hash` | `user_id-created_at-index`, `tenant_id-created_at-index` | none |

`share_tokens_table_enabled = true` adds the table that backs `webbpulse.identity.share_tokens`,
which mints `wps_` tokens for public read only share links. A share token is the third credential
kind beside a session JWT and an API key: holding it is the whole authorization, there is no
account behind it, and it grants exactly what its stored row's capability says. The payload is
opaque to the package, so the one table serves an issue tracker's share link, an album's and a
report's alike. Like an API key it is stored only as a SHA-256 hash with no clear text prefix, so
a leaked table authenticates as nobody. Unlike an API key it carries a TTL on `expires_at`: a
share is a link a person hands out and forgets, and the table would otherwise grow without bound.

| Logical key | Hash key | Index | TTL |
| --- | --- | --- | --- |
| `share-tokens` | `token_hash` | `tenant_id-created_at-index` | `expires_at` |

Hosting an MCP server is both halves, the tables here and the router in the product:

```hcl
module "identity" {
  # ...

  oauth_server_enabled          = true
  oauth_server_mcp_resource_url = "https://${local.api_host}/mcp"
}
```

```python
app.include_router(
    build_identity_router(
        settings,
        hooks,
        stores,
        tokens=TokenService(settings, signing_client(settings)),
        oauth_server_stores=OAuthServerStores(clients=..., codes=..., consents=...),
        tenant_resolver=...,
    )
)
```

Land the tables first and add `oauth_server_mcp_resource_url` once the composition root passes
`oauth_server_stores`, since the package refuses to boot with the flag on and no stores.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name_prefix` | Prefix in front of every name the module builds, joined with a hyphen. | required |
| `issuer` | The issuer byte for byte, carrying the `/api/auth` path. No trailing slash. | required |
| `audience` | The `aud` claim the function stamps and the authorizer requires. | required |
| `registrable_domain` | Registrable domain for the refresh cookie and the WebAuthn RP ID. A bare domain, not a URL. | required |
| `identity_role_name` | Role name the signing, MFA and table policies attach to. | `null` |
| `attach_role_policies` | Create the role policies. The counts read this, not the role name. | `true` |
| `identity_role_arn` | Role ARN named as a principal in the generated KMS key policies. | `null` |
| `signing_key_count` | How many signing keys exist, 1 to 4. | `1` |
| `active_signing_key` | Zero based index of the key that signs. Sets the order of `signing_key_arns`. | `0` |
| `signing_key_spec` | Key spec for the signing keys. RSA only. | `"RSA_2048"` |
| `signing_key_deletion_window_in_days` | Waiting period before KMS deletes a removed signing key. | `30` |
| `signing_key_policy_json` | Complete KMS key policy replacing the generated signing key policy. | `null` |
| `create_signing_key_alias` | Create `alias/<name_prefix>-identity-signing` on the active signer. | `true` |
| `enable_mfa_encryption_key` | Create the symmetric KMS key TOTP seeds are sealed under. | `true` |
| `mfa_encryption_key_arn` | Existing symmetric key to use instead of a created one. | `null` |
| `mfa_encryption_key_deletion_window_in_days` | Waiting period before KMS deletes the envelope key. | `30` |
| `mfa_encryption_key_rotation` | Automatic annual rotation on the envelope key. | `true` |
| `create_mfa_encryption_key_alias` | Create `alias/<name_prefix>-identity-mfa`. | `true` |
| `mfa_encryption_key_policy_json` | Complete KMS key policy replacing the generated envelope key policy. | `null` |
| `mfa_encryption_context_purpose` | Value pinned as `StringEquals` on `kms:EncryptionContext:purpose`. `null` omits the condition. | `"totp"` |
| `tables` | Tables to create, keyed by the package's logical name. `{}` creates none. | the ten identity tables |
| `point_in_time_recovery` | Module wide default for continuous backups on the tables. | `true` |
| `deletion_protection` | Module wide default for the DynamoDB deletion protection flag. | `false` |
| `billing_mode` | `PAY_PER_REQUEST` or `PROVISIONED`. | `"PAY_PER_REQUEST"` |
| `server_side_encryption` | Object `{ enabled, kms_key_arn }` encrypting tables with a managed key. | `null` |
| `table_policy_actions` | DynamoDB actions the generated table grant allows. No `Scan`. | the nine item level actions |
| `additional_table_grants` | Extra roles granted on named tables, keyed by a name that becomes the inline policy name. | `{}` |
| `name_tag` | Add a `Name` tag equal to each table's full name. | `false` |
| `tags` | Tags for every resource the module creates. | `{}` |
| `http_api_id` | HTTP API to create the JWT authorizer on. | `null` |
| `authorizer_name` | Name of the JWT authorizer. Defaults to `<name_prefix>-identity-jwt`. | `null` |
| `authorizer_identity_sources` | Where the authorizer reads the token from. | `["$request.header.Authorization"]` |
| `authorizer_audiences` | Audiences the authorizer accepts. `null` means exactly `[audience]`. | `null` |
| `authorizer_depends_on` | What must already exist and answer before the authorizer is created. | `[]` |
| `wait_for_discovery_document` | Poll the discovery URL and refuse to create the authorizer until it answers. | `true` |
| `discovery_document_attempts` | One second attempts before the poll fails the apply. | `60` |
| `users_stream_enabled` | Plan time known switch for the purge wiring. `false` creates no mapping, no grant and no pass through variables. Requires `attach_role_policies`. | `false` |
| `users_table_stream_arn` | Users table stream the purge mapping reads. Required when `users_stream_enabled` is true. | `null` |
| `identity_function_name` | Identity Lambda the mapping targets. Required when `users_stream_enabled` is true. | `null` |
| `users_key_attribute` | Users table hash key attribute the deleted id is read from. Reaches the app as `IDENTITY_USERS_KEY_ATTRIBUTE`. | `"id"` |
| `users_stream_batch_size` | Stream records per invocation. | `10` |
| `users_stream_batching_window_seconds` | How long the mapping waits to fill a batch. | `5` |
| `users_stream_maximum_retry_attempts` | Retries before a failing record is dropped. `-1` retries until it expires. | `10` |
| `users_stream_starting_position` | `LATEST` or `TRIM_HORIZON`. | `"LATEST"` |
| `users_stream_events_path` | Path the adapter posts to and the app mounts the purge route on. | `"/events"` |
| `oauth_server_enabled` | Create the three OAuth 2.1 authorization server tables. | `false` |
| `oauth_server_tables` | The server tables, in the same object shape as `tables`. Created only when the switch is on. | the three package tables |
| `oauth_server_mcp_resource_url` | The RFC 8707 resource MCP tokens are bound to. Set it and `identity_environment` carries `IDENTITY_MCP_OAUTH_ENABLED` and `IDENTITY_MCP_RESOURCE_URL`. Requires `oauth_server_enabled`. | `null` |
| `api_keys_table_enabled` | Create the `api-keys` table. Independent of the server switch. | `false` |
| `api_keys_table` | The `api-keys` table, in the same object shape as one `tables` entry. | the package table with both indexes |
| `api_keys_table_key` | Logical key the `api-keys` table is created under. | `"api-keys"` |
| `share_tokens_table_enabled` | Create the `share-tokens` table. Independent of the other two switches. | `false` |
| `share_tokens_table` | The `share-tokens` table, in the same object shape as one `tables` entry. | the package table with the tenant index and a TTL |
| `share_tokens_table_key` | Logical key the `share-tokens` table is created under. | `"share-tokens"` |

Object shapes for the two map inputs:

```hcl
tables = map(object({
  attributes = list(object({ name = string, type = string }))
  hash_key   = string
  range_key  = optional(string)
  global_secondary_indexes = optional(list(object({
    name               = string
    hash_key           = string
    range_key          = optional(string)
    projection_type    = optional(string, "ALL")
    non_key_attributes = optional(list(string))
  })), [])
  ttl_attribute          = optional(string)
  point_in_time_recovery = optional(bool)
  deletion_protection    = optional(bool)
  tags                   = optional(map(string), {})
}))

additional_table_grants = map(object({
  role_name = string
  tables    = list(string)
  actions   = optional(list(string))
}))
```

## Outputs

| Name | Description |
| --- | --- |
| `signing_key_arns` | The signing keys, active signer first. This is `IDENTITY_SIGNING_KEY_ARNS`. |
| `active_signing_key_arn` | The key that signs today, which is `signing_key_arns[0]`. |
| `signing_key_ids` | Key id of each key, in creation index order rather than signing order. |
| `signing_key_alias` | `alias/<name_prefix>-identity-signing`, null when the alias is off. |
| `signing_key_alias_arn` | ARN of the signing key alias, null when not created. |
| `signing_policy_json` | The signing grant as a policy document, for attaching by hand. |
| `mfa_encryption_key_arn` | The key TOTP seeds are sealed under, which is `IDENTITY_DATA_KEY_ARN`. Null when there is none. |
| `mfa_encryption_key_id` | Key id of the envelope key, null when the module did not create one. |
| `mfa_encryption_key_alias` | `alias/<name_prefix>-identity-mfa`, null when the key or the alias is off. |
| `mfa_encryption_key_alias_arn` | ARN of the envelope key alias, null when not created. Not usable as an IAM policy resource. |
| `mfa_policy_json` | The envelope grant as a policy document, null when there is no key. |
| `table_names` | Logical key to full table name. |
| `table_arns` | Logical key to table ARN. |
| `table_arns_list` | Every table ARN as a list, sorted by table key. |
| `tables` | Logical key to `{ name, arn, id }`. |
| `table_policy_json` | The table grant as a policy document, including the index wildcard. |
| `additional_table_grant_policy_json` | Grant name to the policy document attached to that grant's role. |
| `authorizer_id` | Id of the JWT authorizer, null when `http_api_id` was not given. Attach it to protected routes. |
| `authorizer_name` | Name of the authorizer, null when not created. |
| `refresh_user_index_name` | Name of the `refresh-tokens` index keyed by `user_id`, which is `IDENTITY_REFRESH_USER_INDEX`. Null when the configured table carries no such index. |
| `identity_environment` | The `IDENTITY_*` variables that follow from this module's own resources. |
| `issuer` | The issuer, echoed back. |
| `audience` | The audience, echoed back. |
| `users_stream_event_source_mapping_uuid` | UUID of the users table stream mapping, null when `users_stream_enabled` is false. |
| `users_stream_policy_json` | The stream read grant as a policy document, null when `users_stream_enabled` is false. |
| `oauth_server_enabled` | Whether the authorization server tables exist, echoed back. |
| `oauth_server_table_names` | Logical key to full table name for the three server tables only, empty when the switch is off. |
| `consent_user_index_name` | Name of the `oauth-consents` index keyed by `user_id`, which `DynamoConsentStore` takes as `user_index`. Null when the switch is off. |
| `api_keys_table_enabled` | Whether the `api-keys` table exists, echoed back. |
| `api_keys_table_name` | Full name of the `api-keys` table, null when the switch is off. |
| `api_keys_user_index_name` | Name of the `api-keys` index keyed by `user_id`, which is `API_KEY_USER_INDEX`. Null when the switch is off. |
| `api_keys_tenant_index_name` | Name of the `api-keys` index keyed by `tenant_id`, which is `API_KEY_TENANT_INDEX`. Null when the switch is off. |
| `share_tokens_table_enabled` | Whether the `share-tokens` table exists, echoed back. |
| `share_tokens_table_name` | Full name of the `share-tokens` table, null when the switch is off. |
| `share_tokens_tenant_index_name` | Name of the `share-tokens` index keyed by `tenant_id`, which is `SHARE_TOKEN_TENANT_INDEX`. Null when the switch is off. |

## Purging identity rows when a user is deleted

Identity owns rows keyed by a user id in ten tables, but it does not own the user record: that row
lives in the product's own users table. A product hard deleting a user therefore leaves credentials,
passkeys, TOTP factors and refresh tokens behind with nothing pointing at them.

Setting `users_stream_enabled = true` closes that gap. The module creates an event source mapping from
the users table's DynamoDB Stream to the identity function, filtered to `REMOVE` events, and grants
the function's role the four stream read actions. The identity package mounts a route that reads the
deleted user id out of `dynamodb.Keys` and deletes that user's identity rows.

This lives in `identity` rather than in `lambda-function` because `identity` already owns the
identity function's grants and its environment: `identity_role_name`, `attach_role_policies` and
`identity_environment` are all here, and the purge is one more grant and three more variables on the
same role and the same map. `lambda-function` is generic and knows nothing about identity, so
putting an identity-shaped event source mapping in it would give every function in the fleet an
input only one of them can use. The function itself is still not created here, which is why the
mapping takes `identity_function_name` as a string.

```hcl
module "tables" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/dynamodb-tables"
  version = "~> 2.17"

  name_prefix = local.prefix

  tables = {
    users = {
      attributes       = [{ name = "id", type = "S" }]
      hash_key         = "id"
      stream_view_type = "KEYS_ONLY"
    }
  }
}

module "identity" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/identity"
  version = "~> 2.17"

  name_prefix        = local.prefix
  issuer             = "https://${local.api_host}/api/auth"
  audience           = "${local.prefix}-api"
  registrable_domain = local.registrable_domain

  identity_role_name   = module.lambda_domain["identity"].role_id
  identity_role_arn    = module.lambda_domain["identity"].role_arn
  attach_role_policies = true

  users_stream_enabled   = true
  users_table_stream_arn = module.tables.stream_arns["users"]
  identity_function_name = module.lambda_domain["identity"].function_name
  users_key_attribute    = "id"
}
```

`identity_environment` then carries `AWS_LWA_PASS_THROUGH_PATH`, `IDENTITY_EVENTS_PATH` and
`IDENTITY_USERS_KEY_ATTRIBUTE` on top of what it already carried, so the function picks the route up
from the same merge it already does.

## Gotchas

- JWT claims arrive at `authorizer.jwt.claims` as a string map, so `exp` is a string, not a number.
- The Lambda Web Adapter passes the request context header as plain JSON, not base64.
- Discovery and JWKS are fetched at CreateAuthorizer time, so the issuer must be live before apply.
- Gate direct invocation of the function with an `x-origin-verify` header; the authorizer only
  protects the API route.
- Leave `http_api_id` null on the first apply of a new environment and set it on a later one, once
  the identity function is deployed and both `.well-known` routes answer anonymously.
- The two `.well-known` routes must carry `authorization_type = "NONE"`. API Gateway's validator
  fetches them from outside with no credentials of ours.
- `depends_on` orders API calls, not their effects. `wait_for_discovery_document` polls the real URL
  because stage auto deploy, `LastUpdateStatus` and a container cold start all lag a 201.
- The poll needs `curl` and network reach from wherever Terraform runs. Set it false and own the
  ordering yourself if you have neither.
- Protected routes are not created here. A route naming the authorizer must come after it while the
  discovery routes must come before it, and one `for_each` cannot express both.
- `POST <issuer>/login/totp` must not sit behind the authorizer: the MFA ticket carries an audience
  of `<issuer>/mfa`, so the gateway rejects it with a 401 that reaches no log of ours.
- The role policies count off `attach_role_policies`, not off `identity_role_name`, because a role
  id that is unknown at plan time makes Terraform refuse to plan with `Invalid count argument`.
- `signing_key_spec` must stay RSA. The HTTP API JWT authorizer verifies RSA signatures only, so an
  ECC spec produces a key no authorizer can use.
- Rotate by adding a key and promoting it on a later apply, never by mutating one: the `kid` is
  derived from the key material, so rotating in place orphans every issued token.
- Lowering `signing_key_count` schedules a key for deletion. The deletion window is the last chance
  to notice an already-issued token still references it, so never lower it in the same change that
  raises it.
- Deleting the MFA envelope key makes every stored TOTP seed permanently unreadable, and the only
  way back is every enrolled user re-enrolling.
- With no envelope key and no `mfa_encryption_key_arn`, `IDENTITY_DATA_KEY_ARN` is absent and TOTP
  enrolment refuses to construct rather than storing a seed in the clear.
- With `IDENTITY_TOTP_CIPHER = secret` the seeds are sealed under `mfa_master_key` from the app
  secret, not under the KMS envelope key, so rotating that master key makes every stored seed
  unreadable and every enrolled user has to re-enrol.
- `registrable_domain` is close to irreversible: the WebAuthn RP ID is hashed into every credential,
  so changing it invalidates every passkey already registered.
- `refresh-tokens` carries `user_id-family_id-index` so a password change or reset can sign every
  other device out. The package reads its name from `IDENTITY_REFRESH_USER_INDEX`, which
  `identity_environment` already carries; a consumer that overrides `tables` and drops the index
  gets no variable, and those other sessions stay signed in with no error anybody sees.
- The index projects `KEYS_ONLY` on purpose. `token_hash`, `user_id` and `family_id` are all the
  revoking write needs, and a wider projection would cost a write on every rotation of the hot path
  to serve the cold one.
- Adding the index to a table that already exists is an in place update with no downtime, but
  DynamoDB backfills it asynchronously and allows only one index build at a time. Until the backfill
  reports `ACTIVE`, a query against it returns partial results, so land the index and let it finish
  before deploying the package version that reads it.
- `identity_environment` carries no product strings (`IDENTITY_ENVIRONMENT`, `IDENTITY_RP_NAME`,
  `IDENTITY_PRODUCT_NAME`, `IDENTITY_SUPPORT_EMAIL`, `IDENTITY_FRONTEND_BASE_URL`); merge it first
  so a product override wins.
- Every key named in an `additional_table_grants` entry's `tables` must be a key of `tables`, checked
  at plan time.
- `oauth-states` and `oauth-links` are not the authorization server's tables. They are the social
  login side, where this package is an OAuth client against Google and GitHub and stores the CSRF
  state and the provider subject to user mapping. The server side is `oauth_server_enabled`, and a
  product that confuses the two ends up with an MCP server whose `/authorize` writes into the table
  that holds Google sign-in state.
- `oauth_server_enabled = true` creates and grants the tables but does not turn the package's own
  flag on. `IDENTITY_MCP_OAUTH_ENABLED` reaches the function only when
  `oauth_server_mcp_resource_url` is also set, because `build_identity_router` raises at startup
  when the flag is on and no `oauth_server_stores` was passed. Infrastructure that flipped the flag
  by itself would turn a missing product argument into a function that will not boot, so the tables
  land first and the product flips the flag when its composition root is ready.
- `oauth-consents` carries no TTL on purpose. A grant that silently expired would send a user back
  through an authorization screen they have no way to predict, and the record is small. A consumer
  overriding `oauth_server_tables` should not add one.
- `authorization-codes` sets `point_in_time_recovery = false`, matching `login-attempts`. Every row
  lives at most ten minutes and is deleted by the exchange that spends it, so continuous backups
  would pay to restore rows that were already invalid.
- The consent GSI's name reaches the package as a constructor argument rather than an environment
  variable. `DynamoConsentStore` defaults `user_index` to `CONSENT_USER_INDEX`, which is the same
  `user_id-index` string, so a consumer that renames the index in `oauth_server_tables` has to pass
  `consent_user_index_name` through to that constructor or listing a user's grants queries an index
  that does not exist.
- The `api-keys` table carries `tenant_id-created_at-index` as well as `user_id-created_at-index`.
  The user index answers one person's key list; the tenant index answers "every key in this
  workspace", which a multi-tenant admin page asks and the `key_hash` partition cannot. Without it
  that page is a table scan. Both names are package constants read in code, not from the
  environment.
- `share-tokens` carries a TTL on `expires_at` where `api-keys` carries none, and the difference is
  deliberate. An API key is revoked explicitly by the person who minted it, so reclaiming one on a
  timer would delete a working credential nobody retired. A share link has no such owner watching
  it, so without the TTL the table grows for as long as the product runs. Expiry is still checked
  on the read path, because the DynamoDB sweep is not prompt: a row past `expires_at` can sit
  readable for hours, and a share token whose expiry only the sweep enforced would keep opening the
  link that whole time.
- `share-tokens` and `api-keys` are separate tables rather than one credential table with a kind
  attribute, because the two authenticate as different things. A share token's subject is the
  literal `share` and it acts as nobody, while an API key acts as the person who minted it inside
  their tenant. The `wps_` and `wpk_` prefixes are what route a presented bearer value to the right
  verifier without parsing it, so a product that merged the tables would be deciding authority by a
  stored attribute it also has to trust.
- Neither `api-keys` index name is in `identity_environment`, and neither is the `share-tokens`
  tenant index, because the package reads no environment variable
  for them. `IDENTITY_REFRESH_USER_INDEX` is the one index whose name the package does look up that
  way, and adding variables the package ignores would read as configuration that does nothing.
- One authorizer per module instance. A product needing several on the same API creates the extra
  ones itself from `issuer` and `audience`.
- `users_stream_enabled`, not the stream ARN, is what the counts key off. When the users table's
  `stream_view_type` is turned on in the same apply, `module.tables.stream_arns["users"]` is unknown
  at plan time, and a count that reads it fails the plan outright with `Invalid count argument`.
  A boolean written literally in the consumer's config is always known, so enabling the stream and
  wiring the purge fit in one apply. The ARN and `identity_function_name` are still required when the
  boolean is true, checked by a precondition on the mapping at apply time, by which point the ARN is
  known.
- `CreateEventSourceMapping` still resolves the stream ARN during the create call, so the table's
  stream has to be created before the mapping in the same apply, which the dependency on the ARN
  already orders.
- The identity package must be at least `0.28.0`. Earlier versions mount no route at
  `IDENTITY_EVENTS_PATH`, so the adapter's pass through POST 404s, every record fails, and the
  mapping retries the shard until the records expire.
- Setting `users_stream_enabled = true` turns pass through on for the whole function. Leave it false
  until the deployed package is `0.28.0` or later; the three environment variables and the mapping land
  together on purpose, so there is no state where one is configured without the other.
- Changing the users table's `stream_view_type` mints a new stream ARN and detaches this mapping. The
  ARN is an input here, so Terraform replaces the mapping on the next apply rather than silently
  reading a stream nobody writes to.
- `KEYS_ONLY` is enough. The handler reads only `dynamodb.Keys`, and a wider view type pays for
  images on every write to the users table to serve the deletes alone.
- A users table keyed by something other than `id` must set `users_key_attribute`. The handler looks
  the key up by name, so a mismatch is a record that fails rather than a row deleted by accident.
- The mapping `depends_on` the stream grant. Lambda checks the function role can read the stream
  during `CreateEventSourceMapping`, so without the edge a fresh apply races the policy and fails the
  create with a permissions error that looks like a misconfigured role.
- `attach_role_policies = false` and `users_stream_enabled = true` cannot be combined, and the plan
  refuses it. The mapping is created here, so it can only be ordered behind a grant created here; a
  grant the consumer attaches outside the module is invisible to that edge and the create would race
  it. A consumer that owns its own policies leaves `users_stream_enabled` false and builds the
  mapping itself from the `users_stream_policy_json` output, where it can order both.
- The one apply that creates the identity role still needs `attach_role_policies = false`, so wire
  the stream on a later apply rather than the same one.
