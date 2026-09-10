output "signing_key_arns" {
  description = "The identity signing keys, active signer first. This is the list webbpulse.identity reads as IDENTITY_SIGNING_KEY_ARNS: the head signs and every element is published in the JWKS. Ordered by active_signing_key and never sorted, because the order is the rotation design rather than presentation."
  value       = local.signing_key_arns
}

output "active_signing_key_arn" {
  description = "ARN of the key that signs today, which is the first entry of signing_key_arns."
  value       = local.active_signing_key_arn
}

output "signing_key_ids" {
  description = "Key id of each signing key, indexed as the module created them rather than in signing order. Use signing_key_arns for anything the application reads."
  value       = [for k in aws_kms_key.identity_signing : k.key_id]
}

output "signing_key_alias" {
  description = "Alias of the active identity signing key, alias/<name_prefix>-identity-signing, or null when create_signing_key_alias is false. KMS accepts an alias anywhere it accepts a key id for Sign and GetPublicKey, and it is a pure function of name_prefix, so passing it to a consumer closes a dependency loop with a string rather than a resource reference."
  value       = one(aws_kms_alias.identity_signing[*].name)
}

output "signing_key_alias_arn" {
  description = "ARN of the signing key alias, null when the alias is not created."
  value       = one(aws_kms_alias.identity_signing[*].arn)
}

output "signing_policy_json" {
  description = "IAM policy document granting kms:Sign and kms:GetPublicKey on every signing key this module owns. Already attached to identity_role_name when that is set; this output is for a consumer composing one inline policy out of several statements or attaching it to a role the module was not told about."
  value       = local.signing_policy_json
}

# ---------------------------------------------------------------------------
# The MFA envelope key
# ---------------------------------------------------------------------------

output "mfa_encryption_key_arn" {
  description = "ARN of the symmetric KMS key TOTP seeds are sealed under, which is what the package reads as IDENTITY_DATA_KEY_ARN. The key this module created, or mfa_encryption_key_arn when a consumer supplied its own, or null when neither exists. Null is the signal that TOTP enrolment will refuse: EnvelopeCipher will not construct without a key id."
  value       = local.mfa_key_arn
}

output "mfa_encryption_key_id" {
  description = "Key id of the MFA envelope key, null when the module did not create one. Use mfa_encryption_key_arn for anything the application reads or an IAM policy names."
  value       = one(aws_kms_key.identity_mfa[*].key_id)
}

output "mfa_encryption_key_alias" {
  description = "Alias of the MFA envelope key, alias/<name_prefix>-identity-mfa, or null when the key or the alias is not created. KMS accepts an alias anywhere it accepts a key id for GenerateDataKey and Decrypt, and it is a pure function of name_prefix, so passing it to a consumer takes no resource reference."
  value       = one(aws_kms_alias.identity_mfa[*].name)
}

output "mfa_encryption_key_alias_arn" {
  description = "ARN of the MFA envelope key alias, null when the alias is not created. An alias ARN is not usable as an IAM policy resource: name mfa_encryption_key_arn there instead."
  value       = one(aws_kms_alias.identity_mfa[*].arn)
}

output "mfa_policy_json" {
  description = "IAM policy document granting kms:GenerateDataKey and kms:Decrypt on the MFA envelope key, conditioned on the encryption context purpose. Null when there is no key. Already attached to identity_role_name when that is set; this output is for a consumer composing one inline policy out of several statements or attaching it to a role the module was not told about."
  value       = local.mfa_key_exists ? local.mfa_policy_json : null
}

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

output "table_names" {
  description = "Logical key to full table name. This is the map an application passes to its Lambda so the code never rebuilds a table name from a prefix. The keys are the package's logical names, so table_names[\"refresh-tokens\"] is what webbpulse.dynamodb.table_name resolves to."
  value       = { for key, table in aws_dynamodb_table.this : key => table.name }
}

output "table_arns" {
  description = "Logical key to table ARN."
  value       = { for key, table in aws_dynamodb_table.this : key => table.arn }
}

output "table_arns_list" {
  description = "Every table ARN as a list, sorted by table key, ready to drop into an IAM policy resource list."
  value       = local.table_arns_list
}

output "tables" {
  description = "Logical key to { name, arn, id }, for a consumer that needs more than one attribute of a table without a second lookup."
  value = {
    for key, table in aws_dynamodb_table.this : key => {
      name = table.name
      arn  = table.arn
      id   = table.id
    }
  }
}

output "table_policy_json" {
  description = "IAM policy document granting table_policy_actions on every table this module created and on their indexes. Already attached to identity_role_name when that is set. The index wildcard is included because three flows Query a named index: the refresh token family revocation reads family_id-generation-index, the passkey login lookup reads credential_id-index and listing a user's OAuth links reads user_id-index."
  value       = local.table_policy_json
}

# ---------------------------------------------------------------------------
# The authorizer
# ---------------------------------------------------------------------------

output "authorizer_id" {
  description = "Id of the JWT authorizer, null when http_api_id was not given. Attach it to the routes that require a token, either as the http-api module's per-route authorizer_id or on a standalone aws_apigatewayv2_route. It is deliberately not attached to anything here: a route naming this authorizer must be created after it while the discovery routes must be created before it, and one for_each cannot express both."
  value       = one(aws_apigatewayv2_authorizer.identity_jwt[*].id)
}

output "authorizer_name" {
  description = "Name of the JWT authorizer, null when it was not created."
  value       = one(aws_apigatewayv2_authorizer.identity_jwt[*].name)
}

# ---------------------------------------------------------------------------
# The environment block
# ---------------------------------------------------------------------------

output "identity_environment" {
  description = <<-EOT
    The IDENTITY_ environment variables that follow from this module's own resources, ready to
    merge into the identity function's environment:

      IDENTITY_ISSUER, IDENTITY_AUDIENCE, IDENTITY_SIGNING_KEY_ARNS (a JSON array, active signer
      first), IDENTITY_COOKIE_DOMAIN, IDENTITY_RP_ID and, when an MFA envelope key exists,
      IDENTITY_DATA_KEY_ARN.

    Every name is a field of webbpulse.identity.IdentitySettings, whose env_prefix is IDENTITY_, so
    the composition root builds the settings object straight from the environment.

    IDENTITY_DATA_KEY_ARN is present only when there is a key to name, either one this module
    created or one supplied through mfa_encryption_key_arn. IdentitySettings.data_key_arn defaults
    to an empty string and EnvelopeCipher refuses to construct on one, so an absent variable and an
    empty one mean the same thing to the package and omitting it keeps the rendered environment
    honest about which keys exist.

    It is deliberately not the whole block. IDENTITY_ENVIRONMENT, IDENTITY_RP_NAME,
    IDENTITY_PRODUCT_NAME, IDENTITY_SUPPORT_EMAIL and IDENTITY_FRONTEND_BASE_URL are product
    strings this module has no resource behind and no business inventing, so the consumer merges
    them alongside this map. Merge this one last so a product override wins.
  EOT

  value = local.identity_environment
}

output "issuer" {
  description = "The issuer, echoed back so a consumer can read it from one place. Byte identical to the iss claim, to the issuer member of the discovery document, and to the authorizer's configured issuer."
  value       = var.issuer
}

output "audience" {
  description = "The audience, echoed back. Byte identical to the aud claim the identity function stamps and to what the authorizer requires."
  value       = var.audience
}
