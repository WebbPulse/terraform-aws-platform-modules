# Changelog

One tag covers every submodule in this repository, so this file is per release, not per module.
Each entry names the modules a release touched. The latest three releases are written out in full.
Everything older is a one line summary, and the tag message plus the GitHub release stay the
authoritative record for them.

An entry marked **no plan change** is one an existing consumer can take without reviewing a diff.

## 2.19.0

### `staging-access-gate`: the cookie signing material is published as outputs **no plan change**

The shared e2e suite drives the staging sites through a real browser, and both staging sites sit
behind this gate, so the suite has to present the same CloudFront signed cookies a browser gets from
the login Lambda. Everything it needs to mint them already exists in the module, but none of it was
an output: the test role had to rebuild the SSM parameter path from the naming convention and read
the CloudFront public key id out of the console.

Four outputs are added. `signing_key_ssm_parameter_name` and `signing_key_ssm_parameter_arn` name
the SecureString holding the RSA private key, the ARN being what a consumer writes into the
`ssm:GetParameter` statement. `signing_key_pair_id` is the CloudFront public key id that goes in the
`CloudFront-Key-Pair-Id` cookie. `cookie_domain` echoes the input back so the signed policy resource
and the cookie scope come from one value rather than two that can drift.

Neither the parameter name nor the ARN is marked sensitive, because neither is: the key itself stays
in the SecureString and is never an output. Marking them would force a consumer to launder them
through a sensitive value to build an IAM policy, and would print the resulting policy document as
redacted in every plan.

Grant the read in staging only. Nothing else changes: no inputs, no resources, no existing output, so
an existing consumer takes this with an empty plan.

## 2.18.0

### `dynamodb-tables` and `identity`: global secondary index keys move to `key_schema` **no plan change**

aws provider 6.29.0 added a nested `key_schema` block to `global_secondary_index` and deprecated the
`hash_key` and `range_key` arguments inside it. Both modules wrote the deprecated form, so every plan
that touched an indexed table logged `hash_key is deprecated. Use key_schema instead.` once per index.
The four WebbPulse workspaces raised sixteen of these between them. The top level table `hash_key` and
`range_key` are not deprecated and are untouched.

Both modules now emit one `key_schema` block for the hash key and, where the index defines one, a
second for the range key. The two forms are mutually exclusive within a single index block, so the
deprecated arguments are gone rather than set alongside.

No input changes. `global_secondary_indexes` still takes `hash_key` and `range_key` and the module
translates them, so no consumer edits a root module for this.

The provider reads an index's keys back into `hash_key` and `range_key` whichever form created it, and
suppresses the resulting diff when `key_schema` is set. Its own acceptance test for the transition
asserts a no-op plan, so an existing index is neither replaced nor updated in place. The
`required_providers` floor for both modules moves from `>= 5.100` to `>= 6.32.1`, the release that
fixed a perpetual diff when an index defined a range key through `key_schema`. The `< 7.0` ceiling is
unchanged. Every WebbPulse workspace already resolves 6.64.0, so no consumer moves provider version to
take this.

## 2.17.1

### `identity`: the users stream purge wiring is gated on a plan time known boolean

The purge resources counted off `var.users_table_stream_arn != null`. A consumer turning
`stream_view_type` on its users table in the same apply that wires the purge has a stream ARN that is
unknown at plan time, and Terraform refuses to plan an unknown count at all, with
`Invalid count argument`. WebbPulse-Portfolio staging had to split the change across two applies with
a temporary workspace variable to get past it.

A new `users_stream_enabled` bool, default `false`, is now the switch. Every count, conditional local
and validation keys off it instead of off the ARN, so the value gating the plan is one the consumer
writes literally and Terraform always knows. `users_table_stream_arn` and `identity_function_name`
are still required when it is true, now checked by preconditions on the event source mapping, which
run at apply time and so never need the ARN's value during the plan. `attach_role_policies = false`
with the stream enabled is still refused at plan time.

Every input and output is kept, and a consumer that sets neither the boolean nor the ARN sees no plan
change.

**Set `users_stream_enabled = true` to keep the purge wiring.** The default is `false`, so a consumer
that passed only `users_table_stream_arn` gets the mapping, the stream grant and the three pass
through environment variables destroyed until it adds the boolean. CarModPicker staging and Portfolio
staging are the only adopters and both are updated alongside this release; no production stack sets
the ARN yet.

## 2.17.0

### `identity`: a deleted user's identity rows are purged from the users table stream

Identity owns rows keyed by a user id across ten tables but owns no user record, so a product hard
deleting a row from its own users table left credentials, passkeys, TOTP factors and refresh tokens
behind with nothing pointing at them. Nothing failed and nothing logged; the rows simply stayed.

The `identity` module gains an optional `users_table_stream_arn`. When it is set, alongside
`identity_function_name`, the module creates an `aws_lambda_event_source_mapping` from that stream to
the identity function and grants the function's role `dynamodb:DescribeStream`, `GetRecords`,
`GetShardIterator` and `ListStreams` on the stream. The mapping filters to `REMOVE` events, reports
`ReportBatchItemFailures` so one bad record does not replay a whole batch, bisects on error and
bounds retries at ten so a poison record cannot block its shard for the full 24 hours.

`identity_environment` gains `AWS_LWA_PASS_THROUGH_PATH`, `IDENTITY_EVENTS_PATH` and
`IDENTITY_USERS_KEY_ATTRIBUTE`, but only when the stream ARN is set. One input feeds both paths, so
the path the Lambda Web Adapter posts a non-HTTP invocation to and the path the application mounts
the purge route on cannot drift apart.

This landed in `identity` rather than `lambda-function` because `identity` already owns the identity
function's role policies and its environment map, while `lambda-function` is generic and would have
gained an input only one function in the fleet could use.

The mapping `depends_on` the grant: Lambda checks the role can read the stream during
`CreateEventSourceMapping`, so without that edge a fresh apply races the policy. For the same reason
`attach_role_policies = false` and a stream ARN are refused at plan time, because a grant attached
outside the module cannot be ordered before a mapping created inside it. A consumer that owns its own
policies leaves the stream ARN null and builds the mapping from `users_stream_policy_json`.

**Requires the identity package at `0.28.0` or later.** Earlier versions mount no route at
`IDENTITY_EVENTS_PATH`, so the pass through POST 404s and the mapping retries until the records
expire. The mapping and the three variables land together, so there is no half-configured state.

**Plan change for an existing consumer:** none. `users_table_stream_arn` defaults to null, which
creates no mapping, no grant and no new environment variables.

**Plan change for a consumer opting in:** one new event source mapping, one new inline role policy,
and one in place update of the identity function's environment. The users table's stream must already
be enabled, because `CreateEventSourceMapping` resolves the ARN during the create call.

### `identity`: the refresh-tokens table carries a user index again

`refresh-tokens` was keyed by `token_hash` with a single index on `family_id`, so nothing could
enumerate the families belonging to one user. A password change or a password reset therefore could
not sign the user's other devices out: `DynamoRefreshTokenStore.revoke_all_for_user` raised, and the
session service logged `session.revoke_all_unsupported` and reported nothing revoked. Every other
device stayed signed in with the old password.

The default `refresh-tokens` table gains a second index, `user_id-family_id-index`, hashed on
`user_id` and ranged on `family_id`, projecting `KEYS_ONLY`. `token_hash` comes from the table key
and the other two from the index key, which is everything the revoking write needs, so the hot
rotation path pays for nothing it does not use.

The index name reaches the application as `IDENTITY_REFRESH_USER_INDEX`, which `identity_environment`
now carries and the new `refresh_user_index_name` output exposes on its own. Both resolve from the
configured table rather than from a constant, so a consumer that overrides `tables` without the index
gets a null output and no environment variable rather than a name pointing at nothing.

**Plan change for a consumer on the default `tables`:** one in place update of the `refresh-tokens`
table adding a global secondary index, and one in place update of the identity function's
environment. The table is not replaced and stays available throughout. DynamoDB backfills the index
asynchronously and it does not answer queries until its status is `ACTIVE`, so let the backfill
finish before deploying the package version that reads it.

**Plan change for a consumer that overrides `tables`:** none until it adds the index to its own
`refresh-tokens` entry. Until it does, sign out everywhere stays a no op for that product.

### `dynamodb-tables`: **no plan change**

A Gotchas line only, noting that a users table feeding the identity purge mapping has to set
`stream_view_type` here first and that `KEYS_ONLY` is enough.

## 2.15.1

### `http-api`: the default access log explains an authorizer denial

The default `access_log_format` carried request, response and integration fields, none of which say
anything when an authorizer refuses a request before any integration runs. A 401 logged
`integrationStatus` and `integrationLatency` as `-` and nothing else, so the reason lived only in the
authorizer's own logs, and for a JWT authorizer it did not live anywhere at all.

Three fields join the default, and every existing field stays: `authorizerError`
(`$context.authorizer.error`), `errorMessage` (`$context.error.message`) and `errorType`
(`$context.error.responseType`). `authorizerError` is the first field to read for a 401 with no
integration call.

Callers that pass their own `access_log_format` are unaffected; the input still replaces the default
outright rather than merging with it.

**Plan change for a consumer that does not set `access_log_format`:** one in place update of the
stage's `access_log_settings.format`. Both consumers pin `~> 2.9`, so they pick this up on their next
run with no pin bump.

## 2.15.0

### `staging-access-gate`: log retention drops to the 7 days the estate standardised on

Seven day retention is the locked decision for this estate, and every consumer already passes 7
wherever a retention input exists: `access_log_retention_days` on both APIs, `log_retention_days` on
every domain and stream consumer Lambda, and the Transaction Search group in both repositories. The
gate was the one place the number was never passed, so its two Lambda log groups sat at the module's
own default of 14 and were the only groups in staging keeping logs twice as long as the standard.

Neither consumer sets `log_retention_days` on this module, so the default was the whole story. It is
now 7, and the input also gains the validation block its siblings in `lambda-function` and
`http-api` already carry, which rejects a number CloudWatch Logs does not accept at plan time rather
than at apply.

**Plan change for a consumer that does not set `log_retention_days`:** an in place update of
`retention_in_days` on the gate's login and authorizer log groups, from 14 to 7. Both consumers pin
`~> 2.12`, so they pick this up on their next run with no pin bump. A consumer that wants 14 can say
so explicitly.

### `staging-access-gate`: the empty audience check now reports its own error

Writing the tests turned up a validation that could never fail. The `identity_jwt.audience` check
read `length(coalesce(try(var.identity_jwt.audience, null), "")) > 0`, and `coalesce` raises when
every argument is null or an empty string. An empty audience therefore surfaced as `Call to function
"coalesce" failed: no non-null, non-empty-string arguments` rather than the message the block
carries, and no input could make the condition evaluate to `false`. It is now
`try(var.identity_jwt.audience, "") != ""`, which reports the intended error, and a test pins it.

**No plan change.** A configuration that plans today planned before.

### Every module now ships a `terraform test` suite

Five modules had tests and ten did not. All fifteen do now, so the layout section's claim that each
module directory carries "its own tests" is true rather than aspirational.

The new suites follow the existing ones: `command = plan` against a mocked provider, `override_data`
for the account and partition lookups, one long snake case `run` name per invariant, and an
`error_message` on every assertion that says why the invariant matters rather than restating the
condition. They cover the main variable branches on and off, the `validation` blocks by way of
`expect_failures`, and the outputs the two consumers actually read.

Two things worth recording, because both are easy to write and neither tests anything:

- **An output compared to the resource attribute it is defined as.** `output.role_arn ==
  aws_iam_role.this.arn` is unknown at plan time so it cannot evaluate at all, and where `outputs.tf`
  defines the output as exactly that attribute it restates the definition and would never fail. The
  suites assert plan knowable configuration instead.
- **An ordering asserted over a set.** `notification` and `subscriber` on the budget and anomaly
  resources, `subscriber_email_addresses`, and `name_servers` on `aws_route53_zone` are all sets, so
  none has an addressable index or an order to preserve. Those invariants are written as membership
  and cardinality over the set instead.

Where a value genuinely is computed, the suites supply it with `override_resource` and
`override_during = plan` and then assert the shape a consumer wires up, rather than dropping the
assertion: `invoke_arn` must be the API Gateway path form rather than the function ARN, and
`role_id` must be the plain name `aws_iam_role_policy` takes.

Two provider behaviours the suites now pin, both of which read the opposite way to the intuition:
the AWS provider folds `domain_name` into `subject_alternative_names`, so an apex plus one wildcard
reads back as two elements rather than one; and `aws_route53_zone.name_servers` is a set.

CI needed no new wiring: the discover job already builds its matrix from `modules/*/tests`. It now
also fails if any module directory has no `tests` directory, so a module cannot be added without a
suite and the coverage cannot quietly regress.

`VALIDATE_SKIP` keeps both of its entries. `acm-certificate` and `staging-dns` declare
`configuration_aliases`, and a module that does can never `terraform validate` as a root module:
validate has no test file to read, so the alias is unwired and it fails on "Provider configuration
not present". `terraform test` covers them instead, because the `.tftest.hcl` file supplies the
aliased provider itself. No `providers` mapping is needed in the `run` blocks; a top level aliased
provider block in the test file is wired up automatically.

**No plan change.** No module input, output or resource changed for the test work; the only
behavioural change in this release is the retention default above.

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

`staging-access-gate`: the enforced route key list and the signing public key PEM move out of the
Lambda environment, which Lambda caps at 4096 bytes, and into a rendered `identity_jwt_config.json`
inside the deployment package. CI gains a `node-tests` job. One in-place update of the authorizer
function.

## 2.10.0

`identity`: new `attach_role_policies` bool, default true, that the three role policy resources
count off, so an unknown `identity_role_name` no longer breaks the plan with `Invalid count
argument`. No plan change for a consumer already passing a role name.

## 2.9.1

`staging-access-gate`: the authorizer function description now fits Lambda's 256 character limit,
which 2.9.0 could exceed with `identity_jwt` enabled. One in-place description update.

## 2.9.0

`http-api` and `staging-access-gate`: identity access tokens enforced at the gateway. `http-api`
gains `identity_jwt`, `identity_jwt_depends_on` and a per-route `require_identity_jwt` that puts
marked routes behind a native JWT authorizer as a second route resource; `staging-access-gate` gains
`identity_jwt` and `identity_jwt_route_keys` so its own Lambda does the same check behind the gate
cookie. Additive, no plan change for a consumer that sets neither.

## 2.8.0

`identity`: the M5 passkey tables (`passkeys` with a `credential_id-index` GSI, `webauthn-challenges`
with a TTL) and the M6 OAuth tables (`oauth-states` with a TTL, `oauth-links` with a `user_id-index`
GSI). Additive, no input or output changed.

## 2.7.0

`identity`: the M4 tables `totp-factors` and `recovery-codes`, plus an optional symmetric KMS
envelope key for the TOTP seed via `enable_mfa_encryption_key`, with rotation on and the grant
conditioned on an encryption context purpose. Adds `IDENTITY_DATA_KEY_ARN` and five `mfa_*` outputs.
Taking it adds two tables, one key, one alias and one role policy.

## 2.6.0

New module `identity`: the RSA signing keys with an ordered rotation list, the identity DynamoDB
tables with the key schemas the `webbpulse.identity` package requires, the signing and table grants,
an optional API Gateway JWT authorizer, and the `identity_environment` map. No plan change for
existing consumers.

## 2.5.1

`http-api`: `authorizer_id` now resolves to null unless the route's effective `authorization_type`
is `CUSTOM` or `JWT`, ending a perpetual in-place diff on `NONE` and `AWS_IAM` routes.

## 2.5.0

`dynamodb-tables`: new optional per-table `stream_view_type`, which enables a DynamoDB stream on
that table. No plan change for a consumer that sets nothing.

## 2.4.0

`api-alarms`: `rate_limit_fail_open_alarm` turns `rate_limit_failed_open` log records into one
metric and one alarm, for the rate limiter allowing traffic when it cannot reach its table. Off by
default, so no plan change. Check the log shape first: the default JSON pattern matches a top level
field, not a substring in the message.

## 2.3.0

`staging-access-gate`: read the region as `region` and require provider 6.x.

## 2.2.0

`api-alarms`: `lambda_function_names` no longer caps at 10. The list is split into groups of at most
10, in list order, each with its own errors and throttles alarm pair; the first group keeps the
existing unsuffixed names and later groups are numbered from 2. New plural alarm name and ARN
outputs. No plan change at 10 or fewer names. Note that `lambda_aggregate_threshold` applies within
a group, not across the estate, and that appending to the list never re-chunks an earlier group.

## 2.1.0

`api-alarms`: aggregate Lambda alarms over a function per domain. `lambda_function_names` plus
`lambda_aggregate_alarm` build one errors and one throttles metric math alarm summing every listed
function. Capped at 10 names, lifted in 2.2.0. Off by default.

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
