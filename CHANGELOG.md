# Changelog

One tag covers every submodule in this repository, so this file is per release, not per module.
Each entry names the modules a release touched. Releases before 2.2.0 were documented in their tag
messages and on the GitHub release; they are summarised here from those, and the tag message stays
the authoritative record for them.

Consumers pin `~> MAJOR.MINOR` and pick up later minors on their next plan, so an entry marked
**no plan change** is one an existing consumer can take without reviewing a diff.

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
