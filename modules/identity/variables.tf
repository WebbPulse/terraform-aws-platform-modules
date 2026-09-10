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
  description = "Name of the identity Lambda's IAM role, which is what an aws_iam_role_policy takes as its role argument. The module attaches the signing and table policies to it. Usually module.lambda_domain[\"identity\"].role_id. Leave null to create no role policies at all and attach the policy JSON outputs by hand."
  type        = string
  default     = null
}

variable "identity_role_arn" {
  description = "ARN of the identity Lambda's role, named as the principal in the signing key policy. A KMS key policy names a principal ARN rather than a role name, so this is a separate input from identity_role_name. Leave null to omit the principal statement, which leaves the key reachable only through the account root statement and IAM policies in the account."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Signing keys
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

variable "tables" {
  description = <<-EOT
    The identity tables to create, keyed by the logical name the package knows them by. The
    default is the four tables the identity flows read and write, with the keys, index and TTL
    attributes that `webbpulse.identity.storage` and `webbpulse.identity.lockout` define. Those key
    schemas are the package's contract rather than this module's preference: a table whose hash key
    does not match what the store writes fails at request time, not at apply time.

    The shape is the dynamodb-tables module's table object, so a product that wants a fifth
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
    # Hash user_id, range credential_type, no TTL ever. Holds the password hash as
    # credential_type = "password". Separating the hash from the user record means a route that
    # returns a user cannot accidentally serialise one.
    credentials = {
      attributes = [
        { name = "user_id", type = "S" },
        { name = "credential_type", type = "S" },
      ]
      hash_key  = "user_id"
      range_key = "credential_type"
    }

    # Hash token_hash, so the hot path "is this presented token valid" is a single GetItem on the
    # primary key with no index in the way. The GSI is for the other operation, revoking a whole
    # family, and is never on the verification path.
    "refresh-tokens" = {
      attributes = [
        { name = "token_hash", type = "S" },
        { name = "family_id", type = "S" },
        { name = "generation", type = "N" },
      ]
      hash_key = "token_hash"
      global_secondary_indexes = [
        {
          name      = "family_id-generation-index"
          hash_key  = "family_id"
          range_key = "generation"
        },
      ]
      ttl_attribute = "expires_at"
    }

    # One table for both verification and reset: the two differ only in a TTL and a template, and
    # two tables would double the Terraform for that.
    "identity-tokens" = {
      attributes    = [{ name = "token_hash", type = "S" }]
      hash_key      = "token_hash"
      ttl_attribute = "expires_at"
    }

    # Hash identity_key ("email#<lower>" or "ip#<addr>"), range attempted_at, so the range key is
    # the timestamp and an append never overwrites. Rows expire after 30 days.
    #
    # No point in time recovery by default, and unlike the other three that is not the environment
    # switch talking: every row is a failure counter inside a lookback window, so there is nothing
    # here worth restoring to a point in time.
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

# ---------------------------------------------------------------------------
# The JWT authorizer
# ---------------------------------------------------------------------------

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
