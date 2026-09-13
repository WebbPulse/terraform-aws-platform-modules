variable "name_prefix" {
  description = "Prefix put in front of every name this module builds, joined with a hyphen. Usually local.prefix, for example webbpulse-staging, which gives a signing key alias of alias/webbpulse-staging-identity-signing and a table named webbpulse-staging-credentials. The identity package's webbpulse.dynamodb.table_name builds the same \"<prefix>-<logical>\" shape, so this value and the application's table prefix are the same string."
  type        = string

  validation {
    condition     = !endswith(var.name_prefix, "-")
    error_message = "name_prefix must not end with a hyphen: the module already joins it to each name with one."
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,48}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, starting with a letter or digit."
  }
}

variable "issuer" {
  description = <<-EOT
    The identity issuer, byte for byte. This exact string is three things at once: the `iss` claim
    the token service signs, the `issuer` member of the discovery document, and the `issuer` on the
    JWT authorizer. A mismatch between any two of them presents as every request being denied with
    nothing in any log to say why, and a trailing slash is the classic way to produce one, which is
    why the validation below refuses one.

    It carries the standard's `/api/auth` path, for example
    https://api.staging.webbpulse.com/api/auth. The path is not cosmetic: API Gateway appends
    `/.well-known/openid-configuration` to whatever it is given, so the discovery document has to
    answer under that path rather than at the origin.

    The host has to resolve and serve TLS from outside AWS, because API Gateway fetches the
    discovery document from its own infrastructure at CreateAuthorizer time. An execute-api
    endpoint that has been switched off by disable_execute_api_endpoint cannot serve it.
  EOT

  type = string

  validation {
    condition     = startswith(var.issuer, "https://")
    error_message = "issuer must be an https URL: API Gateway fetches the discovery document over the public internet and will not accept a plaintext issuer."
  }

  validation {
    condition     = !endswith(var.issuer, "/")
    error_message = "issuer must not end with a trailing slash. API Gateway appends /.well-known/openid-configuration to it, and a trailing slash yields a double slash that fetches nothing."
  }
}

variable "audience" {
  description = "The `aud` claim the identity function stamps on every access token, and the audience the JWT authorizer requires. The standard's convention is \"<product>-api\" carrying the environment, for example webbpulse-portfolio-staging-api, so a staging token is not accepted by production."
  type        = string

  validation {
    condition     = length(var.audience) > 0
    error_message = "audience must not be empty: the authorizer matches the token's aud claim against it."
  }
}

variable "registrable_domain" {
  description = <<-EOT
    The registrable domain the refresh cookie and WebAuthn are scoped to, for example
    webbpulse.com or staging.webbpulse.com. It is the registrable domain rather than the API host,
    so `www.` and any future subdomain share credentials.

    This value is close to irreversible. The WebAuthn RP ID is hashed into every credential by the
    authenticator and is immutable for that credential's life, so changing it later invalidates
    every passkey already registered. A passkey registered against staging not working in
    production is correct behaviour rather than a problem.
  EOT

  type = string

  validation {
    condition     = !startswith(var.registrable_domain, "http")
    error_message = "registrable_domain is a bare domain, not a URL: webbpulse.com, not https://webbpulse.com."
  }
}

variable "identity_role_name" {
  description = "Name of the identity Lambda's IAM role, which is what an aws_iam_role_policy takes as its role argument. The module attaches the signing and table policies to it. Usually module.lambda_domain[\"identity\"].role_id. Leave null, with attach_role_policies false, to create no role policies at all and attach the policy JSON outputs by hand."
  type        = string
  default     = null

  validation {
    condition     = !var.attach_role_policies || var.identity_role_name != null
    error_message = "attach_role_policies is true but identity_role_name is null. Pass the identity Lambda's role name, or set attach_role_policies to false to create no role policies."
  }
}

variable "attach_role_policies" {
  description = "Set false to create no role policies even when identity_role_name is given. The three aws_iam_role_policy resources count off this boolean rather than off identity_role_name, because a consumer usually passes module.lambda_domain[\"identity\"].role_id and that value is unknown at plan time when the role itself is still to be created. An unknown count is not a wrong count: Terraform refuses to plan at all, with Invalid count argument. This input is known at plan time by construction, so the count always is too. Leave it true for the ordinary case and set it false for the one apply that creates the role, then set it back."
  type        = bool
  default     = true
}

variable "identity_role_arn" {
  description = "ARN of the identity Lambda's role, named as the principal in the signing key policy. A KMS key policy names a principal ARN rather than a role name, so this is a separate input from identity_role_name. Leave null to omit the principal statement, which leaves the key reachable only through the account root statement and IAM policies in the account."
  type        = string
  default     = null
}

variable "signing_key_count" {
  description = <<-EOT
    How many identity signing keys exist, one to four. One is the steady state; a second is a
    rotation in progress.

    Rotation in this design is by adding a key and serving both through an overlap, never by
    mutating one. The `kid` is the base64url SHA-256 of the DER SubjectPublicKeyInfo, so it is a
    function of the key material itself: rotating material behind a single key id changes what
    GetPublicKey returns, the derived `kid` follows it, and every already-issued token then
    references a `kid` the JWKS no longer serves. That is why aws_kms_key automatic rotation stays
    off and why this is a count rather than a flag.

    Raising this adds a key. Lowering it schedules one for deletion, and the deletion window is the
    last chance to notice that an already-issued token still references it, which is the one
    mistake in this design with no recovery. Never lower it in the same change that raises it.
  EOT

  type    = number
  default = 1

  validation {
    condition     = var.signing_key_count >= 1 && var.signing_key_count <= 4 && floor(var.signing_key_count) == var.signing_key_count
    error_message = "signing_key_count must be a whole number from 1 to 4. One key is the steady state and a second is a rotation in progress; more than four is not a rotation, it is a mistake."
  }
}

variable "active_signing_key" {
  description = <<-EOT
    Which key signs, as a zero based index into the keys the module creates. It decides the order
    of the signing_key_arns output, which is what the package reads: the head of that list signs
    and every element is published in the JWKS.

    A rotation is therefore two applies rather than one. Raise signing_key_count to add the new key
    and deploy, so the JWKS publishes both while the old one still signs; then move
    active_signing_key to the new index and deploy, so the new key signs and the old one stays
    published for long enough that every token it signed has expired. Promoting in the same apply
    that creates the key would sign with a key no verifier has fetched yet.
  EOT

  type    = number
  default = 0

  validation {
    condition     = var.active_signing_key >= 0 && floor(var.active_signing_key) == var.active_signing_key
    error_message = "active_signing_key must be a whole number of zero or more."
  }

  validation {
    condition     = var.active_signing_key < var.signing_key_count
    error_message = "active_signing_key must index a key that exists: it is zero based, so with signing_key_count = 2 the only valid values are 0 and 1."
  }
}

variable "signing_key_spec" {
  description = "Key spec for the signing keys. RSA_2048 is the only value the HTTP API JWT authorizer can verify: its token validation workflow says \"Currently, only RSA-based algorithms are supported\", which is what rules out ES256 and forces RS256. 2048 rather than 4096 because a larger key means a larger signature and a slower, more expensive kms:Sign on the hot path of every login and every refresh, for no benefit any verifier can see."
  type        = string
  default     = "RSA_2048"

  validation {
    condition     = contains(["RSA_2048", "RSA_3072", "RSA_4096"], var.signing_key_spec)
    error_message = "signing_key_spec must be an RSA spec: RSA_2048, RSA_3072 or RSA_4096. The HTTP API JWT authorizer verifies RSA signatures only, so an ECC spec produces a key no authorizer can use."
  }
}

variable "signing_key_deletion_window_in_days" {
  description = "Waiting period before KMS actually deletes a key removed from the list. The 30 day maximum rather than the 7 day floor: dropping a key an already-issued token still references is the one mistake in this design with no recovery, and the waiting period is the last chance to notice."
  type        = number
  default     = 30

  validation {
    condition     = var.signing_key_deletion_window_in_days >= 7 && var.signing_key_deletion_window_in_days <= 30
    error_message = "signing_key_deletion_window_in_days must be between 7 and 30, which is the range KMS accepts."
  }
}

variable "signing_key_policy_json" {
  description = "A complete KMS key policy for the signing keys, replacing the generated one. Leave null for the generated policy: an account root statement plus kms:Sign and kms:GetPublicKey for identity_role_arn. The root statement is not optional in a hand-written replacement either, because without it IAM policies in the account have no effect on the key and the key can become unmanageable."
  type        = string
  default     = null
}

variable "create_signing_key_alias" {
  description = "Create alias/<name_prefix>-identity-signing pointing at the active signing key. The alias is what a caller passes where KMS accepts a key id, and it exists to break the dependency cycle a key ARN would create when the key policy names the Lambda role. An alias is unique per account and region, so turn this off if something else already owns that name."
  type        = bool
  default     = true
}

variable "enable_mfa_encryption_key" {
  description = <<-EOT
    Create the symmetric KMS key that TOTP seeds are sealed under, and grant the identity role
    kms:GenerateDataKey and kms:Decrypt on it.

    On by default, because a TOTP seed is the one identity secret that cannot be hashed. The server
    has to reproduce the code to check it, so unlike a password there is no one-way form and unlike
    a passkey there is no public half: a read of the seed table is a complete compromise of the
    second factor for every user in it. DynamoDB's own encryption at rest is under an AWS owned key
    and is transparent to every principal that can call Query, which is exactly the attacker this
    is about. Sealing the seed under a separate key means reading a usable one needs
    dynamodb:GetItem AND kms:Decrypt with the right encryption context, and every decrypt is a
    CloudTrail event.

    Turn it off only for a product that has TOTP disabled outright, or one supplying its own key
    through mfa_encryption_key_arn. With the key off and no ARN supplied, IDENTITY_DATA_KEY_ARN is
    absent from identity_environment and webbpulse.identity.crypto.EnvelopeCipher refuses to
    construct, so TOTP enrolment fails loudly rather than storing a seed in the clear.
  EOT

  type    = bool
  default = true
}

variable "mfa_encryption_key_arn" {
  description = "An existing symmetric KMS key to seal TOTP seeds under, instead of the one this module would create. Set it together with enable_mfa_encryption_key = false to point the package at a key owned elsewhere. It must be SYMMETRIC_DEFAULT with ENCRYPT_DECRYPT usage, and it must not be a signing key: a key that can both sign tokens and decrypt seeds makes the blast radius of either compromise the whole of both. The module grants the identity role GenerateDataKey and Decrypt on whatever ARN ends up in use, so a supplied key is granted the same way a created one is."
  type        = string
  default     = null

  validation {
    condition     = var.mfa_encryption_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.mfa_encryption_key_arn))
    error_message = "mfa_encryption_key_arn must be a KMS key ARN, not a key id or an alias: the IAM statement names it as a resource and an alias ARN there grants nothing."
  }
}

variable "mfa_encryption_key_deletion_window_in_days" {
  description = "Waiting period before KMS actually deletes the MFA envelope key. The 30 day maximum, for the same reason the signing key takes it: the key is the only thing that can open every stored TOTP seed, and deleting it makes every enrolled second factor permanently unreadable with no way back other than every user re-enrolling."
  type        = number
  default     = 30

  validation {
    condition     = var.mfa_encryption_key_deletion_window_in_days >= 7 && var.mfa_encryption_key_deletion_window_in_days <= 30
    error_message = "mfa_encryption_key_deletion_window_in_days must be between 7 and 30, which is the range KMS accepts."
  }
}

variable "mfa_encryption_key_rotation" {
  description = <<-EOT
    Automatic annual rotation on the MFA envelope key. ON by default, and deliberately the opposite
    of the signing key's setting.

    The two are opposite because the failure modes are opposite. A signing key's `kid` is derived
    from its material, so rotating material behind one key id orphans every already-issued token.
    An envelope key has no such identifier: KMS keeps every previous backing key and picks the right
    one from the wrapped blob, so a data key wrapped last year still decrypts after a rotation with
    nothing to re-encrypt and no seed to re-enrol. Rotation here is free and is what the control
    exists for.
  EOT

  type    = bool
  default = true
}

variable "create_mfa_encryption_key_alias" {
  description = "Create alias/<name_prefix>-identity-mfa pointing at the MFA envelope key. Same purpose as the signing key's alias: a pure function of name_prefix that a consumer can pass where KMS accepts a key id without taking a resource reference. An alias is unique per account and region."
  type        = bool
  default     = true
}

variable "mfa_encryption_key_policy_json" {
  description = "A complete KMS key policy for the MFA envelope key, replacing the generated one. Leave null for the generated policy, which mirrors the signing key's shape: an account root statement plus kms:GenerateDataKey and kms:Decrypt for identity_role_arn, conditioned on the encryption context purpose. The root statement is not optional in a hand-written replacement either, because without it IAM policies in the account have no effect on the key and the key can become unmanageable."
  type        = string
  default     = null
}

variable "mfa_encryption_context_purpose" {
  description = <<-EOT
    The value of the `purpose` half of the encryption context, pinned in both halves of the grant
    as a StringEquals condition on kms:EncryptionContext:purpose.

    "totp" is webbpulse.identity.crypto.TOTP_ENCRYPTION_PURPOSE, and the package sends it on every
    GenerateDataKey and every Decrypt. Changing it here without changing it there produces a key
    the identity function may not use, presenting as enrolment failing with an AccessDenied that
    names no context.

    The other half of the context, `user_id`, is deliberately NOT pinned: its value is a different
    string for every user, so no fixed condition can express it. What the purpose condition buys is
    that this key cannot be used for anything other than TOTP seeds, so a later feature that wants
    envelope encryption gets its own key rather than quietly widening this one.

    Set it to null to omit the condition entirely, for a consumer running a package version that
    sends a different context.
  EOT

  type    = string
  default = "totp"
}

variable "tables" {
  description = <<-EOT
    The identity tables to create, keyed by the logical name the package knows them by. The
    default is the ten tables the identity flows read and write, with the keys, indexes and TTL
    attributes that `webbpulse.identity.storage` and `webbpulse.identity.lockout` define. Those key
    schemas are the package's contract rather than this module's preference: a table whose hash key
    does not match what the store writes fails at request time, not at apply time.

    The shape is the dynamodb-tables module's table object, so a product that wants a further
    identity table adds an entry here in the shape it already knows.

    Set it to {} to create no tables at all, for a consumer whose tables are already created by its
    own dynamodb-tables call and which wants only the key and the authorizer from this module.
  EOT

  type = map(object({
    attributes = list(object({
      name = string
      type = string
    }))
    hash_key  = string
    range_key = optional(string)
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

  default = {
    credentials = {
      attributes = [
        { name = "user_id", type = "S" },
        { name = "credential_type", type = "S" },
      ]
      hash_key  = "user_id"
      range_key = "credential_type"
    }

    "refresh-tokens" = {
      attributes = [
        { name = "token_hash", type = "S" },
        { name = "family_id", type = "S" },
        { name = "generation", type = "N" },
        { name = "user_id", type = "S" },
      ]
      hash_key = "token_hash"
      global_secondary_indexes = [
        {
          name      = "family_id-generation-index"
          hash_key  = "family_id"
          range_key = "generation"
        },
        {
          name            = "user_id-family_id-index"
          hash_key        = "user_id"
          range_key       = "family_id"
          projection_type = "KEYS_ONLY"
        },
      ]
      ttl_attribute = "expires_at"
    }

    "identity-tokens" = {
      attributes    = [{ name = "token_hash", type = "S" }]
      hash_key      = "token_hash"
      ttl_attribute = "expires_at"
    }

    "login-attempts" = {
      attributes = [
        { name = "identity_key", type = "S" },
        { name = "attempted_at", type = "S" },
      ]
      hash_key               = "identity_key"
      range_key              = "attempted_at"
      ttl_attribute          = "expires_at"
      point_in_time_recovery = false
    }

    "totp-factors" = {
      attributes = [{ name = "user_id", type = "S" }]
      hash_key   = "user_id"
    }

    "recovery-codes" = {
      attributes = [
        { name = "user_id", type = "S" },
        { name = "code_hash", type = "S" },
      ]
      hash_key  = "user_id"
      range_key = "code_hash"
    }

    passkeys = {
      attributes = [
        { name = "user_id", type = "S" },
        { name = "credential_id", type = "S" },
      ]
      hash_key  = "user_id"
      range_key = "credential_id"
      global_secondary_indexes = [
        {
          name     = "credential_id-index"
          hash_key = "credential_id"
        },
      ]
    }

    "webauthn-challenges" = {
      attributes    = [{ name = "challenge_id", type = "S" }]
      hash_key      = "challenge_id"
      ttl_attribute = "expires_at"
    }

    "oauth-states" = {
      attributes    = [{ name = "state", type = "S" }]
      hash_key      = "state"
      ttl_attribute = "expires_at"
    }

    "oauth-links" = {
      attributes = [
        { name = "provider_subject", type = "S" },
        { name = "user_id", type = "S" },
      ]
      hash_key = "provider_subject"
      global_secondary_indexes = [
        {
          name     = "user_id-index"
          hash_key = "user_id"
        },
      ]
    }
  }

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([for a in t.attributes : contains(["S", "N", "B"], a.type)])
    ])
    error_message = "Every attribute type must be S (string), N (number) or B (binary)."
  }

  validation {
    condition = alltrue([
      for t in var.tables : contains([for a in t.attributes : a.name], t.hash_key)
    ])
    error_message = "Each table's hash_key must name one of that table's attributes."
  }

  validation {
    condition = alltrue([
      for t in var.tables : t.range_key == null || contains([for a in t.attributes : a.name], t.range_key)
    ])
    error_message = "A table's range_key, when set, must name one of that table's attributes."
  }

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([
        for g in t.global_secondary_indexes : contains([for a in t.attributes : a.name], g.hash_key)
        && (g.range_key == null || contains([for a in t.attributes : a.name], g.range_key))
      ])
    ])
    error_message = "Every global secondary index hash_key and range_key must name one of the same table's attributes. DynamoDB rejects an index key that has no attribute definition."
  }

  validation {
    condition = alltrue([
      for t in var.tables : alltrue([
        for g in t.global_secondary_indexes : contains(["ALL", "KEYS_ONLY", "INCLUDE"], g.projection_type)
      ])
    ])
    error_message = "Every global secondary index projection_type must be ALL, KEYS_ONLY or INCLUDE."
  }

  validation {
    condition = alltrue([
      for k in keys(var.tables) : can(regex("^[A-Za-z0-9_.-]{1,255}$", k))
    ])
    error_message = "Table keys may hold only letters, digits, underscores, hyphens and dots, which is what DynamoDB allows in a table name."
  }
}

variable "point_in_time_recovery" {
  description = "Module-wide default for continuous backups on the identity tables. A table whose point_in_time_recovery is null takes this. The credential and refresh token tables hold user state, so this defaults to true rather than to the environment switch the other modules use; login-attempts overrides it to false in the default map."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Module-wide default for the DynamoDB deletion protection flag, which makes AWS refuse a DeleteTable call. A table whose deletion_protection is null takes this. Consumers usually pass var.environment == \"production\"."
  type        = bool
  default     = false
}

variable "billing_mode" {
  description = "PAY_PER_REQUEST or PROVISIONED. The identity access patterns are point lookups whose volume tracks sign-ins, which is what on-demand is for, and that is the default."
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED."
  }
}

variable "server_side_encryption" {
  description = "Encrypt the identity tables at rest with a customer managed or AWS managed KMS key instead of the AWS owned key DynamoDB uses by default. null omits the block entirely, which is what a table that never set it has in state; DynamoDB still encrypts, just with the owned key."
  type = object({
    enabled     = bool
    kms_key_arn = optional(string)
  })
  default  = null
  nullable = true
}

variable "table_policy_actions" {
  description = "DynamoDB actions the generated table policy grants the identity role on every table this module creates and on their indexes. The default is the item level set the identity flows use; there is no Scan, because no identity flow scans a table and granting it invites one that does."
  type        = list(string)
  default = [
    "dynamodb:BatchGetItem",
    "dynamodb:BatchWriteItem",
    "dynamodb:DeleteItem",
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:Query",
    "dynamodb:TransactGetItems",
    "dynamodb:TransactWriteItems",
    "dynamodb:UpdateItem",
  ]

  validation {
    condition     = length(var.table_policy_actions) > 0
    error_message = "table_policy_actions must list at least one action."
  }

  validation {
    condition     = alltrue([for a in var.table_policy_actions : startswith(a, "dynamodb:")])
    error_message = "table_policy_actions must only hold dynamodb: actions. This module's policy grants access to its own tables and nothing else."
  }
}

variable "additional_table_grants" {
  description = <<-EOT
    Extra roles that get a grant on some of this module's tables, keyed by a stable name that
    becomes the inline policy's name on the role. The identity function itself is granted through
    identity_role_name and is not expressed here.

    This exists because a second function sometimes has to write an identity-owned table without
    becoming the identity function. The case that drove it is a users domain whose own routes still
    create an account and change a password: those writes belong in the credentials table, the users
    role is not the identity role, and a consumer cannot express the grant itself without naming
    table ARNs this module owns and hard-coding a resource list that a change to tables would
    silently desynchronise.

    Each entry names a role and the logical table keys it reaches. tables must be keys of var.tables,
    checked at plan time, so a typo or a table this module does not create fails the plan rather than
    producing a policy that grants nothing. actions defaults to table_policy_actions; pass a narrower
    list to give a consumer less than the identity function has, which is the usual reason to use
    this. Every grant covers the named tables and their indexes, the same shape the identity grant
    takes.

    The map key is known at plan time and the role name need not be, which is what lets a consumer
    pass module.lambda_domain["users"].role_id on the apply that also creates that role. A for_each
    over unknown values would be undecidable; a for_each over known keys is not.

        additional_table_grants = {
          users-credentials = {
            role_name = module.lambda_domain["users"].role_id
            tables    = ["credentials"]
            actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
          }
        }
  EOT

  type = map(object({
    role_name = string
    tables    = list(string)
    actions   = optional(list(string))
  }))

  default = {}

  validation {
    condition = alltrue([
      for grant in var.additional_table_grants : length(grant.tables) > 0
    ])
    error_message = "Every entry of additional_table_grants must name at least one table. An empty list would attach an inline policy whose resource list is empty, which AWS refuses."
  }

  validation {
    condition = alltrue(flatten([
      for grant in var.additional_table_grants : [
        for table in grant.tables : contains(keys(var.tables), table)
      ]
    ]))
    error_message = "Every table named in additional_table_grants must be a key of var.tables. Only the tables this module creates can be granted here, and a name that is not one of them would silently grant nothing."
  }

  validation {
    condition = alltrue([
      for grant in var.additional_table_grants :
      grant.actions == null || length(coalesce(grant.actions, [])) > 0
    ])
    error_message = "An actions list given in additional_table_grants must not be empty. Leave it null to take table_policy_actions."
  }
}

variable "name_tag" {
  description = "Add a Name tag equal to each table's full name, matching the hand-written resources of an estate that carries one. It merges under tags and a table's own tags, so either can override it."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource this module creates, on top of the provider default_tags. Empty is passed to the provider as null so it plans identically to a resource that never set tags."
  type        = map(string)
  default     = {}
}

variable "http_api_id" {
  description = <<-EOT
    Optional API Gateway HTTP API id. When set, a JWT authorizer is created on it validating the
    module's issuer and audience, and its id comes back as the authorizer_id output for the caller
    to attach to routes.

    Leave it null until the discovery document already answers. CreateAuthorizer validates the
    issuer synchronously: API Gateway fetches <issuer>/.well-known/openid-configuration during the
    create call and rejects it with BadRequestException, "Issuer must have a valid discovery
    endpoint ended with '/.well-known/openid-configuration'", when it does not get a discovery
    document back. That is not documented anywhere; it was learned from a failed apply. See
    authorizer_depends_on and the README's ordering section.
  EOT

  type    = string
  default = null
}

variable "authorizer_name" {
  description = "Name of the JWT authorizer. Defaults to \"<name_prefix>-identity-jwt\"."
  type        = string
  default     = null
}

variable "authorizer_identity_sources" {
  description = "Where the authorizer reads the token from. The default is where a bearer token belongs and what every client already sends. API Gateway requires every listed identity source to be present or it answers 401 without evaluating the token."
  type        = list(string)
  default     = ["$request.header.Authorization"]
}

variable "authorizer_audiences" {
  description = "Audiences the authorizer accepts, when more than the module's own audience is needed. Leave null for exactly [audience], which is the usual case. A token's aud claim has to match one entry."
  type        = list(string)
  default     = null
}

variable "authorizer_depends_on" {
  description = <<-EOT
    What must already exist and already answer before the authorizer is created. Pass the values
    that stand for "the two `.well-known` routes exist and the identity function serves them",
    which is usually the whole http-api and Lambda modules, for example
    [module.api, module.lambda_domain].

    This is not tidiness. CreateAuthorizer fetches <issuer>/.well-known/openid-configuration during
    the create call and fails the apply when it does not get a discovery document back, and nothing
    the authorizer references implies that the routes serving it exist. Whole module values are
    coarser than necessary and cost nothing, since both are upstream of this module in every other
    respect anyway.

    Terraform evaluates the count and the keys of a module before its depends_on, so passing an
    unknown value here is fine but passing one to http_api_id is not.
  EOT

  type    = any
  default = []
}

variable "wait_for_discovery_document" {
  description = "Poll <issuer>/.well-known/openid-configuration from wherever Terraform runs, and refuse to create the authorizer until it answers. Only meaningful when http_api_id is set. It needs curl on the machine running Terraform and network reach to the issuer; a consumer without either sets this false and owns the ordering itself, accepting that a create-time failure is then indistinguishable from a real misconfiguration."
  type        = bool
  default     = true
}

variable "discovery_document_attempts" {
  description = "How many one second attempts the discovery poll makes before failing the apply. Sixty is a minute of patience, which is far longer than a cold start and still bounded."
  type        = number
  default     = 60

  validation {
    condition     = var.discovery_document_attempts >= 1 && var.discovery_document_attempts <= 600 && floor(var.discovery_document_attempts) == var.discovery_document_attempts
    error_message = "discovery_document_attempts must be a whole number from 1 to 600."
  }
}
