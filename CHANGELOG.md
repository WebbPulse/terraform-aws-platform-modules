# Changelog

One tag covers every submodule in this repository, so this file is per release, not per module.
Each entry names the modules a release touched. Releases before 2.2.0 were documented in their tag
messages and on the GitHub release; they are summarised here from those, and the tag message stays
the authoritative record for them.

Consumers pin `~> MAJOR.MINOR` and pick up later minors on their next plan, so an entry marked
**no plan change** is one an existing consumer can take without reviewing a diff.

## Unreleased

## 2.14.0

### `api-alarms`: telemetry export failures stop paging as application errors

`<prefix>-application-errors` fires on a single ERROR record at a zero threshold. That is right for
an application fault and wrong for the OTLP span exporter, which logs at ERROR whenever a trace
batch does not reach the X-Ray endpoint. On a Lambda sandbox teardown that is routine: the container
freezes mid-export, the POST times out or its signature has aged into a 403, and the exporter says
so at ERROR.

In Portfolio staging it was not merely noisy, it was the entire signal. Every ERROR record in
`/aws/lambda/webbpulse-staging-identity` over seven days was an export failure, 97 of them across
two loggers, and the alarm flapped continuously while no request had failed. An alarm that is always
in ALARM reports nothing.

A dropped trace is a gap in observability, not a failed request. The two now have separate alarms:

- **`error_excluded_loggers`** names the loggers whose ERROR records are pipeline failures. It
  defaults to the two OpenTelemetry exporter loggers plus `webbpulse.otel`, and it is excluded from
  the error filter pattern, which `error_filter_pattern` now builds when left at its new `null`
  default. An explicitly supplied pattern still wins outright.
- **`<prefix>-telemetry-export-errors`** is a new aggregate alarm over metric filters matching
  exactly those loggers, at `Sum > 20` over one 1 hour period with missing data not breaching. The
  threshold is a rate rather than zero because a few dropped batches an hour is the normal cost of
  an exporter in a freeze-thaw sandbox. It carries the same SNS actions, so the failure stays
  visible as "tracing is degraded" rather than "the application is erroring".
  `telemetry_alarm_enabled = false` removes it.

The two patterns are complements over one list, so a name moved out of `error_excluded_loggers`
moves its records back onto the application alarm rather than losing them.

`webbpulse.otel` is excluded alongside the library loggers because the shared package wraps the
exporter and re-logs the same failure under its own name. Its only ERROR call site is that wrapper.

One correction worth recording, because the naive form of this change silently breaks the alarm: a
JSON filter pattern's `!=` against a field the record does not carry evaluates false, so a bare
chain of `$.logger != ...` clauses stops matching any ERROR record that has no `logger` field at
all. Those records match neither the error pattern nor the telemetry one and stop alarming
entirely. The built pattern therefore carries a `$.logger NOT EXISTS` arm, and both patterns were
proved with `aws logs test-metric-filter` against real log lines before release.

Cost is one extra custom metric and one extra alarm per environment, not per function.

- New variables `error_excluded_loggers`, `telemetry_alarm_enabled`, `telemetry_alarm_threshold`,
  `telemetry_alarm_period`, `telemetry_alarm_evaluation_periods` and `telemetry_metric_name`.
- `error_filter_pattern` now defaults to `null` and builds from the exclusion list. A consumer that
  passes a literal pattern is unaffected.
- New outputs `error_filter_pattern`, `telemetry_alarm_name`, `telemetry_metric_filter_names` and
  `telemetry_metric`.
- New test suite `modules/api-alarms/tests/telemetry_error_split.tftest.hcl`.

**Plan change for any consumer passing `error_log_groups`:** every error metric filter's pattern
updates in place, and the telemetry filters and alarm are created.


## 2.12.0

### `staging-access-gate`: the authorizer no longer depends on the API it guards

Identity enforcement has never admitted a single authenticated request. Every valid RS256 token was
answered 403, with one line in the authorizer log for each:

```
WARN access token rejected: JWKS unavailable: JWKS fetch returned 403
```

The authorizer verifies a token against the issuer's JWKS, which it fetches over HTTPS. In the gate
topology the issuer is the same HTTP API the authorizer guards, and `/api/auth/.well-known/jwks.json`
carries this very authorizer like every other route. The fetch is made by the Lambda itself, so it
carries none of a browser's credentials: no gate cookie, no origin verification header. The gate
refused it, `keyFor` threw, and the token was denied. The authorizer was, in effect, asking itself
for permission to check permissions.

Nothing in the module's own tests reached it, because they stub the JWKS endpoint, and nothing in
staging verification reached it either: anonymous routes never fetch a key set at all, so a gate
checked only against anonymous traffic looks perfectly healthy. 2.11.0 bundling a PEM into the
package did not help and was never meant to. That PEM is the CloudFront signed cookie key pair,
used for RSA-SHA1 policy verification; the identity signing key is a different key entirely and
has always come from the JWKS.

Two changes, either of which closes the loop, and both are wanted:

- **The JWKS fetch presents the origin verification header.** It is the same credential the gate
  already accepts from CloudFront and from pipelines, read from the same SSM parameter the inbound
  check reads, so the authorizer presents something it already holds to a path that already accepts
  it. Nothing new is granted and the value is never logged.
- **The issuer's `.well-known` subtree is admitted anonymously.** The discovery document and the
  JWKS are public key material, published so that anyone can verify a token this issuer signed.
  They carry no user data and mutate nothing, and every other verifier of these tokens needs them
  reachable without a credential. The new `identity_anonymous_path_prefixes` input renders this,
  defaulting to `<issuer path>/.well-known/` when enforcement is on and to nothing when it is off.
  Pass `[]` for no exemption at all.

The exemption is an exact prefix on the `.well-known` subtree and nothing wider: `/api/auth/login`
and `/api/auth/.well-knownish/secrets` are still gated, which the test suite asserts alongside a
valid token accepted on an enforced route, an expired and a wrong-key token refused, and both
`.well-known` documents answering with no credential.

**Plan change:** one in-place update of the authorizer Lambda (`source_code_hash`, and the rendered
`identity_jwt_config.json` inside the archive). No other resource moves.

## 2.11.0

### `staging-access-gate`: the enforced route key list moves into the deployment package

An apply that turned on identity enforcement in CarModPicker staging failed after a green plan:

```
InvalidParameterValueException: Lambda was unable to configure your environment variables because
the environment variables you have provided exceeded the 4KB limit. Measured size: 4545 bytes
```

Lambda caps the whole environment, keys and values together, at 4096 bytes, and it measures that
only at `UpdateFunctionConfiguration`. Terraform's plan cannot see the limit, so the configuration
was valid right up to the apply. With 95 route keys `IDENTITY_JWT_ROUTE_KEYS` serialised to 3600
bytes on its own, against 869 bytes for the other ten variables including the 451 byte signing
public key PEM.

Neither obvious escape was available. Trimming the list is not a size fix, it is a security change:
a key missing from the list is a route that nobody enforces. Collapsing the list to path prefixes is
worse, because the anonymous guard routes sit under the same prefixes as enforced ones and would
start demanding tokens they must never demand. Exact matching is the point of the design.

So the two values that grow move out of the environment and into the authorizer's deployment
package. The module renders `identity_jwt_config.json` holding the sorted route key list and the
signing public key PEM, writes it into the archive alongside `index.js`, and the handler reads it
once at import time. The environment now holds only short scalars, and it measures the same 397
bytes whether the consumer enforces nothing or three hundred routes.

Because the config file is an `archive_file` source block, its bytes are part of
`output_base64sha256` and therefore part of `source_code_hash`. Adding a route key still changes the
package hash and still redeploys the function, exactly as changing the environment variable did.

A package that somehow lacks the config file fails closed: with no public key nothing verifies, so
signed cookies are refused rather than waved through.

**Not breaking.** The module's inputs are unchanged. Consumers pass `identity_jwt_route_keys` and
the module decides how it reaches the function; that was never part of the interface.

**Plan change:** for a consumer with `identity_jwt` set, one in-place update of the authorizer
function, changing `source_code_hash`, `filename` and the `environment` block. Nothing else moves. A
consumer with `identity_jwt` unset also sees that one update, because the signing public key PEM
left the environment for the package there too.

### CI: the `staging-access-gate` Node suite now runs on every pull request

The module ships three Node functions and a test suite that covers them, and nothing ran it. `fmt`,
`validate` and the plan-only `terraform test` suites all pass over a handler that denies every
request, so a broken handler could reach a consumer as a published tag. `terraform-ci.yml` gains a
`node-tests` job, and `all-checks-passed` now depends on it. The job uses no credentials: keys are
generated in process, SSM is stubbed on the client prototype and the JWKS fetch is stubbed on
`globalThis.fetch`.

The suite gained the coverage this release needed: the enforced list is asserted to come from the
package and not from any environment variable, exact-match semantics are asserted against two
anonymous guard routes and a prefix sibling that is enforced, method is asserted to be part of the
key, and a size test measures the rendered environment against the 4096 byte cap with a 300 key
list.

## 2.10.0

### `identity`: `attach_role_policies`, a plan-time boolean the role policies count off

The three `aws_iam_role_policy` resources counted off `var.identity_role_name == null`. A consumer
passes `module.lambda_domain["identity"].role_id`, which is `aws_iam_role.this.id`, and when that
role is itself still to be created the id is unknown at plan time. Terraform does not defer an
unknown `count`: it refuses to produce a plan at all and reports `Invalid count argument`. That is
what a speculative plan of CarModPicker's `staging` tree against production state hit, in `kms.tf`
and `dynamodb.tf`, and it blocked the production promotion.

`attach_role_policies` is a bool defaulting to true, and all three counts move onto it. Its value is
known by construction, so the count always is too. `identity_role_name = null` keeps its old meaning
of attaching nothing, now written as the pair `attach_role_policies = false`; the halfway state,
true with a null role name, is refused by a validation that reads only the input variables and so
stays decidable even when the role name's value is not.

Outputs are unchanged, including the three `*_policy_json` outputs a consumer attaches by hand when
the policies are off.

**Plan change:** none for a consumer that already passes a role name, which is the default.

## 2.9.1

### `staging-access-gate`: authorizer description fits the Lambda limit

2.9.0 set a description on the gate authorizer function that, with `identity_jwt` enabled, was
longer than the 256 characters Lambda accepts. `UpdateFunctionConfiguration` rejected it, so the
first apply of a consumer turning on `identity_jwt` failed after the plan was green. Both variants
of the description are now short enough with any allowed `name`. **Plan change:** one in-place
update of the authorizer function's description for existing consumers.

## 2.9.0

### `http-api` and `staging-access-gate`: identity access tokens enforced at the gateway

The identity module has signed RS256 access tokens and published a JWKS since 2.5.0, but nothing in
front of the applications checked them. Every route that needed a caller's identity had to verify
the token itself, in each product, and a route that forgot to was open. This moves the check to the
gateway, so an unverified request never reaches application code, and it does it in both
environments with one statement of intent per route.

**Additive and backwards compatible.** Both new inputs default to null or empty and every default
preserves current behaviour. A consumer that adopts 2.9.0 without setting them sees **no plan
change**: `staging-access-gate` merges the new environment variables rather than setting them empty,
and `http-api` creates no authorizer and moves no route.

- **`http-api`: `identity_jwt`, `identity_jwt_depends_on`, and `require_identity_jwt` per route.**
  Marking a route with `require_identity_jwt = true` states that the route needs a caller identity.
  With `identity_jwt` set, the module creates an `aws_apigatewayv2_authorizer` of type JWT and the
  marked routes go behind it: API Gateway verifies the signature against the issuer's JWKS, checks
  `iss`, `aud`, `exp` and `nbf`, and puts the claims at `requestContext.authorizer.jwt.claims`.
  Nothing of ours runs on the request path. New outputs: `identity_jwt_authorizer_id`,
  `identity_jwt_authorizer_name`, `identity_jwt_route_keys`, `route_identity_jwt_required`.
- **The marked routes are a second resource, `aws_apigatewayv2_route.identity_jwt`.** They have to
  be. `CreateAuthorizer` synchronously fetches `<issuer>/.well-known/openid-configuration` from
  outside, with none of our credentials, so the `.well-known` routes must exist and answer
  anonymously **before** the authorizer is created, while the protected routes must be created
  **after** it. One `for_each` cannot be both sides of the same resource; Terraform reports a cycle
  and refuses the graph. The cost of the split is worth knowing before the first apply: a route that
  gains `require_identity_jwt` moves between the two resources, so a plan says replaced rather than
  updated in place. That is seconds of 404 on one path, which is the correct blast radius for
  switching a route from open to token-required, and marking routes in the same apply that first
  sets `identity_jwt` keeps it to one move.
- **`staging-access-gate`: `identity_jwt` and `identity_jwt_route_keys`.** Staging cannot use the
  native authorizer, because an HTTP API route takes exactly one authorizer and on a gated API that
  slot is the gate's. So the gate's own Lambda does both checks: the signed cookie as before, then,
  for the named routes, a valid Bearer access token verified the same way. Leave `identity_jwt` null
  in staging's `http-api` and the routes stay exactly where they are; the marked keys still come out
  of `identity_jwt_route_keys`, and wiring that output into this input is the whole of it. New
  outputs: `identity_jwt_enforced`, `identity_jwt_route_keys`.
- **Route keys, not a second authorizer, because the event does not say.** The natural design is two
  authorizer resources over one Lambda, one demanding a token and one not. It cannot work: a payload
  format 2.0 authorizer event carries no authorizer id, and `routeArn` is a route ARN, so the two
  are indistinguishable from inside the function. What the event does carry is
  `requestContext.routeKey`, which is the same string the consumer already wrote as the map key in
  `routes`. So the keys travel from one module to the other and the Lambda matches them exactly.
  `$default` is refused by a variable validation: as the catch-all it would turn enforcement on for
  every path nobody has routed.
- **The claims arrive in nearly the same shape in both environments, and the difference is
  unavoidable.** A Lambda authorizer's context always lands under `requestContext.authorizer.lambda`,
  and API Gateway stringifies every value and rejects nested objects, so staging cannot literally put
  claims where the native authorizer puts them. It gets as close as the platform permits: one JSON
  string of a string map under a key named `jwt.claims`, plus `sub`, `iss` and `exp` lifted out. One
  line reads both, values are strings on both sides, and both module READMEs carry it.
- **Verification uses `node:crypto`, with no dependency.** `archive_file` zips the Lambda source as
  it sits and no consumer's Terraform run does an `npm install`, so any library would have to be
  vendored here and patched by hand. Node 22 imports a JWK and verifies RS256 natively, and the
  identity module already refuses to sign with anything but RSA. `alg` is read to refuse and never to
  select, which is what closes `alg: none` and RS256-to-HS256 confusion. The JWKS is cached with a
  short TTL, force-refreshed once on an unknown `kid` so a rotation recovers without a redeploy, and
  a stale cache is preferred over failing a request when a fetch fails.
- **Ordering that Terraform cannot express.** `depends_on` orders API calls, not their effects, and
  an auto-deploying stage, an `UpdateFunctionConfiguration` that returns while the update is still in
  progress, and a container cold start all sit between `CreateRoute` returning 201 and an outside
  request getting a discovery document back. `identity_jwt_depends_on` is where the identity function
  goes, and a first apply is best done in two runs: routes and function, then the authorizer.
- **Tests.** Six new `terraform test` runs cover both environments, the anonymous routes staying
  anonymous, and the two configurations the module refuses (an authorizer with no routes behind it,
  and `require_identity_jwt` together with `authorization_type = "NONE"`). A new JS suite verifies a
  valid token, expiry, wrong issuer, wrong audience, an unknown `kid` recovering on refresh, a
  missing header, a missing gate cookie, `alg: none`, HS256 confusion, an `aud` array, clock skew,
  and enforcement being off, against locally generated RSA keys and a stubbed JWKS endpoint.

## 2.8.0

### `identity`: the M5 passkey tables and the M6 OAuth tables

Follows `webbpulse` 0.14.0 and 0.15.0, which ship identity milestones M5 (WebAuthn registration,
passwordless sign-in, credential management) and M6 (the authorization code flow against Google and
GitHub, and account linking). The module gains the four tables those releases added, and nothing
else. **Additive**: no input, output or existing resource changed, so a consumer that passes
`tables` explicitly sees no plan change at all and picks the tables up when it adds them itself.

- **Two tables in the default `tables` map.** `passkeys`, hash `user_id` and range `credential_id`,
  with one global secondary index, `credential_id-index` on `credential_id`, projecting `ALL`. The
  primary key is that way round because the management page reads its own writes: listing a user's
  credentials has to be a consistent `Query` on the base table, and a GSI read cannot be consistent.
  The login lookup goes the other way, credential id to owner, and that one tolerates eventual
  consistency because a credential written by an already-authenticated request is not one somebody
  is signing in with in the same instant. `ALL` rather than `KEYS_ONLY` because the login path reads
  the stored public key and the sign count off the index, and `KEYS_ONLY` would cost a second read
  on every sign-in. **No TTL, and there never may be one**, for the reason `totp-factors` has none:
  a passkey is a second factor, or under `passkeys_passwordless` the only factor, and one that
  vanishes on a schedule is silently removed from an account.
- **`webauthn-challenges`, hash `challenge_id`, no range key, no index, TTL on `expires_at`.** The
  one table in the identity set whose rows are meant to disappear. A WebAuthn challenge is a row
  rather than a signed token because unreplayability is a claim about state and a token cannot make
  it: a JWT verifies exactly as well the second time as the first, so a captured
  options-and-assertion pair replays for the whole of that token's lifetime. The row is written when
  options are generated, deleted when it is consumed, and refused past its deadline whether or not
  DynamoDB has reclaimed it. TTL stays storage reclamation and never access control, which is the
  same rule every other expiring table in the map follows; pointing it at another attribute breaks
  nothing visibly and grows the table forever, which is why `expires_at` is contract.
- **`oauth-states`, hash `state`, no range key, no index, TTL on `expires_at`.** The OAuth analogue
  of `webauthn-challenges`, and a row for the same reason: a state binds a callback to the request
  that started it. It is spent by a conditional `DeleteItem` with `ReturnValues=ALL_OLD`, so it is
  single use even under a concurrent replay, and the ten minute deadline is re-checked on every read
  so an unreclaimed row is refused rather than accepted.
- **`oauth-links`, hash `provider_subject`, no range key, one index `user_id-index` on `user_id`
  projecting `ALL`, no TTL.** The hash key is the provider identity (`<provider>#<subject>`), which
  makes the uniqueness constraint the primary key: attaching a provider is one conditional put on
  `attribute_not_exists(provider_subject)`, so a race resolves to one winner with no read-then-write
  and no synthetic reservation rows. This deliberately diverges from section 4.2 of the standard,
  which sketched a synthetic id with two indexes. `user_id-index` answers "every link for this user",
  which listing and the last-method count in `unlink` both need; it is a GSI rather than a second
  table because two tables would need both rows written and deleted in step with no cross-table
  transaction available, and a half-failed pair is an orphaned link that `unlink` cannot find. **No
  TTL, and there never may be one**: a link is a sign-in method and may be the only one, and the
  package's refusal to unlink the last way in is worth nothing if DynamoDB deletes it on a timer.
- **No policy input changed, and the index wildcard is now load-bearing three times over.** The
  table grant has always named every table this module creates plus `<table arn>/index/*`, so
  `dynamodb:Query` on `credential_id-index` and on `user_id-index` is already allowed and there was
  nothing to add. It is worth stating why that entry exists: DynamoDB authorises an index read
  against `table/<name>/index/<index>`, so a policy naming only `table/<name>` denies a Query that
  read a GSI, with an `AccessDenied` that names the table. Three flows now depend on it, the refresh
  token family revocation, the passkey login lookup and the OAuth link listing, and the comments on
  the resource, the local and the output say so.
- **`identity_environment` is untouched, deliberately.** `IDENTITY_RP_ID` is already there, derived
  from `registrable_domain`, because the RP ID *is* the registrable domain and the module owns that
  input. `IDENTITY_PASSKEYS_ENABLED`, `IDENTITY_RP_NAME` and `IDENTITY_WEBAUTHN_ORIGINS`, and M6's
  `IDENTITY_OAUTH_*` settings alongside them, are product strings and product toggles with no
  resource behind them, which is exactly the category the output has always excluded
  `IDENTITY_RP_NAME`, `IDENTITY_PRODUCT_NAME`, `IDENTITY_SUPPORT_EMAIL` and
  `IDENTITY_FRONTEND_BASE_URL` for. The module has no variable-backed feature toggle to follow as a
  precedent, so adding one here would be the first and would put a product decision behind a module
  input. The consumer merges them alongside the map, as it already does for the other four. The
  OAuth client secrets in particular never belong here: they come from the product's Secrets Manager
  JSON and are passed as an argument the package keeps off its settings object.
- **README**: which of the seven passkey routes must not sit behind the JWT authorizer. The two
  login legs must not, because they are the entry point and the caller holds nothing the authorizer
  would accept; `login/passkey/options` in particular is answerable by anybody by design, since
  answering differently would make an anonymous route an account oracle. The other five do, and each
  reads its subject from the verified claims. Also flagged: the package treats a user-verified
  passkey as two factors, so a user with TOTP enrolled is not challenged for a code after one.
- **Adoption**: a "Coming from 2.7.0" note. Four adds and no moves for a consumer on the default
  map, and the one thing to read the plan for is a **replacement** rather than a create, which is
  what a consumer with a hand-rolled `passkeys` or OAuth table keyed some other way will see. A
  replaced `passkeys` table is every user's credentials gone and a replaced `oauth-links` is every
  user's linked accounts. CarModPicker's existing `oauth_accounts` is the concrete case: it stores
  synthetic uniqueness rows under a different key, so it is not `oauth-links` under another name.

### `identity`: the adoption section now matches what adoption actually looked like

Documentation only. No module input, output or resource changed, so there is **no plan change** and
nothing to pin.

- **The four tables are moves, not creates.** The adoption section said `credentials`,
  `refresh-tokens`, `login-attempts` and `identity-tokens` "do not exist yet at `origin/staging`, so
  those are ordinary creates". That was true when it was written and is not true now:
  WebbPulse-Portfolio#160 created three of them and #162 created `identity-tokens`, all four inside
  `module.dynamodb`. They move out of it at
  `module.dynamodb.aws_dynamodb_table.this["<key>"]`.
- **The worked example is now WebbPulse-Portfolio#164 verbatim** rather than a sketch: all 11 `moved`
  blocks, including that the three M1 KMS resources are two-hop chains through their M0 spike
  addresses. Dropping the first hop of a chain destroys the signing key.
- **The six in-place changes are listed with the reason each one is unavoidable**: the KMS key
  description, which the module composes from `name_prefix`, `signing_key_spec` and `issuer` with no
  input to override it, and three tags on each of the four tables, because `tags` and `name_tag` are
  module wide and there is no per-resource tag input, so no setting of the two keeps both the key's
  existing tags and the tables' absence of them.
- **"0 to destroy" is now stated as the check to read the plan for**, on its own rather than folded
  into a general review note. A destroy on the signing key means an address did not line up, and
  that is the one mistake in this design with no recovery.
- **`table_policy_actions` gotcha called out.** The default drops `dynamodb:Scan`,
  `dynamodb:DescribeTable` and `dynamodb:ConditionCheckItem`, so a consumer whose existing grant
  carried them must pass the input explicitly or lose three permissions on the apply that is meant
  to change nothing.
- **The two M4 tables are flagged as genuine creates** for a consumer coming from 2.6.0. Nothing
  holds them at any address, so there is nothing to move them from.

## 2.7.0

### `identity`: the M4 tables and the TOTP envelope key

Follows `webbpulse` 0.12.0, which ships identity milestone M4: TOTP, recovery codes, the MFA
ticket, step-up and `amr`. The module gains the two tables that release added and the KMS key its
seed encryption needs.

- **Two tables in the default `tables` map.** `totp-factors`, hash `user_id`, no range key and no
  index, because one factor per user means re-enrolling replaces the seed rather than adding a row.
  `recovery-codes`, hash `user_id` and range `code_hash`, so spending a code is a point write on the
  primary key and reading a whole set is one `Query` on the partition. **Neither carries a TTL, and
  neither ever may.** The general rule about mixing expiring and permanent entities is sharper here
  than anywhere else in the map: an expiring refresh token costs a user one extra login, while a
  TOTP factor or a recovery code that vanishes early costs them the account. Both are covered by the
  existing table grant, which already names every table this module creates plus their indexes.
- **An optional symmetric KMS key for the TOTP seed envelope**, `enable_mfa_encryption_key`,
  defaulting to true. A seed is the one identity secret that cannot be hashed, because the server
  has to reproduce the code to check it, so a read of `totp-factors` would otherwise be a complete
  compromise of the second factor for every user in it. The key policy follows the signing key's
  shape, there is an `alias/<name_prefix>-identity-mfa`, and the identity role gets exactly
  `kms:GenerateDataKey` and `kms:Decrypt` scoped to that key ARN. Not `kms:Encrypt`: the package
  uses envelope encryption, so a plaintext seed never reaches KMS. A consumer whose key is owned
  elsewhere sets `mfa_encryption_key_arn` and turns creation off; the grant and the environment
  variable follow the supplied key.
- **Automatic rotation is ON for this key, the opposite of the signing keys.** The signing keys have
  it off because the `kid` is derived from the key material, so rotating one orphans every
  already-issued token. An envelope key has no such identifier: KMS retains every previous backing
  key and selects the right one from the wrapped blob, so a data key wrapped before a rotation still
  opens afterwards, with nothing to re-encrypt and no user to re-enrol.
- **The grant is conditioned on the encryption context**, `StringEquals` on
  `kms:EncryptionContext:purpose` equal to `totp`, in both the key policy and the role policy so
  neither half is wider than the other. Only `purpose` is pinned. The package sends
  `{"user_id": "<id>", "purpose": "totp"}` and KMS enforces the whole context as authenticated
  additional data, but `user_id` is a different value per user and no static condition can name it.
  What the condition buys is that the key cannot be used for anything other than TOTP seeds.
  `mfa_encryption_context_purpose = null` omits it.
- **`identity_environment` gains `IDENTITY_DATA_KEY_ARN`**, which is
  `IdentitySettings.data_key_arn` under the package's `IDENTITY_` prefix. It is present only when
  there is a key to name: the field defaults to an empty string and `EnvelopeCipher` refuses to
  construct on one, so an absent variable and an empty one mean the same thing to the package.
- **New outputs**: `mfa_encryption_key_arn`, `mfa_encryption_key_id`, `mfa_encryption_key_alias`,
  `mfa_encryption_key_alias_arn` and `mfa_policy_json`.
- **README**: which of the six new MFA routes must not sit behind the JWT authorizer.
  `POST <issuer>/login/totp` must not, because it carries an MFA ticket whose audience is
  `<issuer>/mfa` rather than the API's audience, so the gateway rejects it before it reaches the
  function and every MFA login fails at its second step. The other five do sit behind it, and each
  reads its subject from the verified claims rather than from the body.

**Plan change for existing `identity` consumers**, which is what makes this a minor rather than a
patch. Taking 2.7.0 adds two DynamoDB tables, one KMS key, one alias and one IAM role policy. A
consumer that does not want the key sets `enable_mfa_encryption_key = false`; one that does not want
the tables overrides `tables`. Nothing existing is modified or replaced.

## 2.6.0

### New module: `identity`

A product's whole identity layer for the shared identity standard, mounted once per environment.
Portfolio was carrying the KMS half of this hand-written in `terraform/identity.tf` from milestone
M1; the module reproduces those resources exactly, so adopting it is three `moved` blocks and an
empty plan. The tables and the authorizer are new.

- **Signing keys.** One to four `aws_kms_key` resources, `RSA_2048` and `SIGN_VERIFY`, with
  automatic rotation deliberately off: the `kid` is derived from the key material, so rotating
  material behind one key id orphans every already-issued token. Rotation is by adding a key.
  `signing_key_arns` is ordered by `active_signing_key` and never sorted, because the package signs
  with element 0 and publishes every element in the JWKS. An alias tracks the active signer.
- **Tables.** The four identity tables (`credentials`, `refresh-tokens`, `identity-tokens`,
  `login-attempts`) with the exact key schemas, the `family_id-generation-index` GSI and the
  `expires_at` TTL attributes that `webbpulse.identity.storage` and `.lockout` require. The
  credentials table has no TTL by design.
- **Grants.** `kms:Sign` and `kms:GetPublicKey` on every signing key, and item level DynamoDB access
  to every table and index. No `Scan`.
- **Authorizer.** An optional `aws_apigatewayv2_authorizer` of type JWT on a given HTTP API,
  validating the same issuer and audience the function signs with. Off by default, because
  `CreateAuthorizer` synchronously fetches the discovery document and fails the apply when nothing
  is serving it yet. `wait_for_discovery_document` polls the URL first so a cold start does not
  present as a misconfiguration. Protected routes are not created here: the consumer attaches
  `authorizer_id` to avoid a dependency cycle.
- **`identity_environment`** returns the `IDENTITY_*` variables that follow from the module's own
  resources, with the signing key list as a JSON array, ready to merge into the function's
  environment.

**No plan change** for existing consumers: this release adds a module and touches nothing else.

## 2.5.1

### `http-api`: no authorizer id on a route that takes no authorizer

A route whose effective `authorization_type` was `NONE` or `AWS_IAM` was still handed
`var.authorizer_id`. Neither type takes an authorizer: API Gateway accepts the create with one
attached, ignores it and stores nothing, so the route reads back `authorizer_id = ""` while the
configuration still names an authorizer, and every later plan shows a perpetual in-place
`authorizer_id: "" -> "..."` update on it. Portfolio staging hit this on the two public
`.well-known` routes it opts out of the access gate, which have to answer anonymously because the
API Gateway JWT authorizer fetches them itself.

- `authorizer_id` now resolves to `null` unless the route's effective `authorization_type` is
  `CUSTOM` or `JWT`. The per-route `authorizer_id` override is unchanged for those two types, and
  the module-wide `authorizer_id` still reaches every route that does not opt out, `$default`
  included.
- **No plan change** for an API whose routes are all `CUSTOM`, which is every consumer that has not
  set `authorization_type = "NONE"` or `"AWS_IAM"` on a route. A consumer that has one of those
  routes gets a single in-place update on it that then stops recurring.

## 2.5.0

### `dynamodb-tables`: per-table `stream_view_type`

- New optional `stream_view_type` on each table entry (`KEYS_ONLY`, `NEW_IMAGE`, `OLD_IMAGE`,
  `NEW_AND_OLD_IMAGES`). Setting it enables a DynamoDB stream on that table; leaving it null keeps
  the table without a stream. CarModPicker row 22 uses `NEW_AND_OLD_IMAGES` on `users`, `parts`,
  `votes` and `part_listings`.
- **No plan change** for a consumer that sets nothing; each table that sets it gets one in-place
  update enabling the stream.

## 2.4.0

### `api-alarms`: one alarm for the rate limiter failing open

The shared DynamoDB backed rate limiter allows a request when it cannot reach its
`<prefix>-rate-limits` table, and logs a WARNING carrying `rate_limit_failed_open` instead of
refusing traffic. Nothing reported that: the request succeeded, so `AWS/Lambda Errors` stays at zero
and the API returns 200 while the limit is not being enforced. `rate_limit_fail_open_alarm = true`
turns those records into a metric and puts one alarm on it.

- One `aws_cloudwatch_log_metric_filter` per watched log group, named
  `<name_prefix>-<key>-rate-limit-failed-open`, and **one**
  `<name_prefix>-rate-limit-failed-open` alarm summing them. Same dimensionless single metric shape
  as `error_log_groups`, so the alarm count stays at one however many functions the estate holds and
  the alarm is a plain metric alarm rather than metric math.
- The log groups default to `error_log_groups`, so a consumer that already lists its functions there
  does not list them twice. `rate_limit_fail_open_log_groups` names a different set and replaces
  that list rather than merging with it.
- Sum over one 5 minute period at a threshold of 0 with `GreaterThanThreshold` and
  `notBreaching` missing data: a single fail open alarms. Actions go to the module's existing topic.
- New inputs: `rate_limit_fail_open_alarm`, `rate_limit_fail_open_log_groups`,
  `rate_limit_fail_open_filter_pattern`, `rate_limit_fail_open_metric_name`,
  `rate_limit_fail_open_alarm_threshold`, `rate_limit_fail_open_alarm_period` and
  `rate_limit_fail_open_alarm_evaluation_periods`.
- New outputs: `rate_limit_fail_open_alarm_name`, `rate_limit_fail_open_metric_filter_names` and
  `rate_limit_fail_open_metric`. The new alarm also joins `alarm_names` and `alarm_arns`.
- New test suite `modules/api-alarms/tests/rate_limit_fail_open.tftest.hcl`.

**No plan change for an existing consumer.** `rate_limit_fail_open_alarm` defaults to `false` and
nothing else in the module reads the inputs that go with it, so a consumer that upgrades without
touching its module block sees no new resources, including one that already passes
`error_log_groups`. The test suite pins that case.

Check which log shape a service emits before enabling this. The default pattern
`{ $.rate_limit_failed_open IS TRUE }` matches a **top level** JSON field, which is what a logger
given the flag as a record attribute writes. A service that interpolates
`rate_limit_failed_open=True` into its message text has no such field, and a JSON pattern cannot see
inside the message string: the metric would stay flat at 0 and the alarm would report healthy while
the limiter fails open. Those services need a substring pattern instead, and the README section
"The pattern has to match the shape the service actually logs" gives it.

## 2.3.0

`staging-access-gate`: read the region as `region` and require provider 6.x. No `api-alarms` change.

## 2.2.0

### `api-alarms`: the aggregate Lambda alarms chunk past ten functions

`lambda_function_names` no longer caps at 10 names. A CloudWatch alarm's metric math expression may
reference at most 10 metrics, which 2.1.0 enforced with a variable validation; the list is now split
into groups of at most 10 instead, in list order, and each group gets its own errors and throttles
alarm pair.

- The `lambda_function_names <= 10` validation is removed. The list has no length limit.
- The first group keeps the alarm names it has always had, `<name_prefix>-lambda-errors-aggregate`
  and `<name_prefix>-lambda-throttles-aggregate`. Groups past the first are numbered from 2:
  `<name_prefix>-lambda-errors-aggregate-2`, `-3` and so on.
- New outputs: `lambda_aggregate_errors_alarm_names`, `lambda_aggregate_throttles_alarm_names`,
  `lambda_aggregate_errors_alarm_arns`, `lambda_aggregate_throttles_alarm_arns` and
  `lambda_aggregate_function_name_chunks`. These are the outputs to build a composite alarm,
  a dashboard or a runbook on, because they stay correct as the estate grows past 10 functions.
- New test suite `modules/api-alarms/tests/lambda_aggregate_chunking.tftest.hcl`.
- New second module call in `examples/api-alarms-lambda-aggregate` showing the chunked shape.

**No plan change for an existing consumer at 10 or fewer function names.** The alarm resources
stayed on `count`, so one group is still `lambda_aggregate_errors[0]` and
`lambda_aggregate_throttles[0]`, the addresses an existing state already holds, with the same
unsuffixed alarm names and the same `m0 + m1 + ...` expression. No `moved` block is needed or
possible: `moved` requires a constant key, so a `count` index cannot be moved to a computed
`for_each` key, which is why the shape kept `count`. The 2.1.0 test suite passes unedited, and the
new suite asserts the 5 name and the exactly-10 name cases produce the 2.1.0 names at index 0.

Two things to know before growing past 10 functions:

- `lambda_aggregate_threshold` applies **within a group**, not across the estate. At the default of
  0 that is the same behavior as a single alarm. At a raised threshold it is not, because errors
  split across two groups no longer add up. An estate wanting one number for the whole thing wants
  the log based alarm in `error_log_groups`, whose metric is dimensionless.
- The order of `lambda_function_names` now decides which group a function lands in as well as its
  `m0`, `m1` id. Appending never re-chunks an earlier group, because `chunklist` fills each group
  before starting the next, so grow the list at the end rather than inserting.

`lambda_aggregate_errors_alarm_arn` and `lambda_aggregate_throttles_alarm_arn`, the singular outputs
from 2.1.0, keep their names and now report the **first** group's alarm rather than failing on a
list long enough to chunk. A consumer past 10 functions should move to the plural outputs: a
composite alarm built on the singular one would silently cover only the first ten functions.

## 2.1.0

`api-alarms`: aggregate Lambda alarms over a function per domain. `lambda_function_names` plus
`lambda_aggregate_alarm` build one `-lambda-errors-aggregate` and one `-lambda-throttles-aggregate`
metric math alarm summing every listed function, instead of a pair per function. Capped at 10 names
by the CloudWatch metric math ceiling; lifted in 2.2.0. Off by default.

## 2.0.2

Patch release.

## 2.0.1

Patch release.

## 2.0.0

`http-api`: breaking. The module takes an `integrations` map, a `routes` map and
`default_integration` instead of a single backend; per-route throttling and `cors_configuration`
were added, and the `integration_id` output was removed. `moved` blocks adopt a 1.x consumer whose
single integration is named `legacy` with zero changes.

## 1.8.0

`api-alarms`: a CloudWatch Logs metric filter alarm on the errors the application logs, through
`error_log_groups`, plus `lambda_errors_alarm_function_name`. `lambda-function`: `Image` package
type and an X-Ray write policy. New `ecr-repository` and `codeartifact` modules.

## 1.7.1

`api-alarms`: the aggregate DynamoDB throttle alarm became a single Metrics Insights query, because
PutMetricAlarm rejects an alarm holding two of them.

## 1.7.0 and earlier

See the tag messages and the GitHub releases.
