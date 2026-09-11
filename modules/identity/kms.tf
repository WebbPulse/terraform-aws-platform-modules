# ---------------------------------------------------------------------------
# The signing keys.
#
# RSA_2048 and SIGN_VERIFY. The HTTP API JWT authorizer's token validation workflow says
# "Currently, only RSA-based algorithms are supported", which is the single sentence that rules out
# the preferred ES256 and forces RS256.
#
# AUTOMATIC ROTATION IS OFF, AND THAT IS A DECISION RATHER THAN AN OMISSION. The `kid` a verifier
# matches on is the base64url SHA-256 of the DER SubjectPublicKeyInfo, so it is a function of the
# key material itself. Rotating the material behind a single key id changes what GetPublicKey
# returns, the derived `kid` follows it, and every already-issued token then references a `kid` the
# JWKS no longer serves. Rotation in this design is by adding a key and serving both through an
# overlap, never by mutating one, which is what signing_key_count and active_signing_key are for.
# aws_kms_key defaults enable_key_rotation to false; it is written out so the next reader does not
# have to know that.
#
# count rather than for_each, and the index is the contract. The signing_key_arns output is ordered
# by active_signing_key, so which key signs is an input rather than a property of a map's key
# order, and adding a second key never disturbs the first one's address.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "identity_signing" {
  count = var.signing_key_count

  description = "${var.signing_key_spec} signing key ${count.index} for the ${var.name_prefix} identity function's RS256 access tokens. The private half never leaves KMS; the public half is published in the JWKS at ${var.issuer}/.well-known/jwks.json."

  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = var.signing_key_spec
  enable_key_rotation      = false
  deletion_window_in_days  = var.signing_key_deletion_window_in_days

  policy = coalesce(var.signing_key_policy_json, local.generated_signing_key_policy)

  tags = length(local.signing_key_tags) == 0 ? null : local.signing_key_tags
}

# The alias points at the active signer, and it is what a caller passes anywhere KMS accepts a key
# id. It exists to close a dependency loop with a string rather than a resource reference: the key
# policy names the identity function's role, so the key depends on the Lambda; naming the key from
# inside that module's environment variables would make the module depend on the key, and Terraform
# refuses the graph. The alias name is a pure function of name_prefix.
#
# The signing key ARNs are the exception and are passed as real ARNs, because the list is what a
# rotation edits and two aliases would have to be created and swapped in lockstep to express the
# same thing. That direction does not close a cycle: environment variables are an attribute of the
# function rather than of the role, and Terraform's graph is per resource, so the order is role,
# then key, then function.
#
# An alias is unique per account and region. Moving the active signer to another key updates this
# alias in place rather than replacing it.
resource "aws_kms_alias" "identity_signing" {
  count = var.create_signing_key_alias ? 1 : 0

  name          = local.signing_key_alias
  target_key_id = aws_kms_key.identity_signing[var.active_signing_key].key_id
}

# The key policy.
#
# A KMS key policy is not optional the way most resource policies are: without a statement granting
# the account root, IAM policies in the account have no effect on the key at all and the key can
# become unmanageable. So the root statement is always present, and the identity function's role
# then gets exactly the two signing actions on this key and nothing else.
#
# A key policy statement's resource is the key the policy is attached to, so "*" here is that key
# and not every key in the account. That is why the generated document uses it while the IAM policy
# attached to the role names the ARNs.
data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "signing_key" {
  statement {
    sid    = "EnableIAMPoliciesInThisAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.identity_role_arn == null ? [] : [var.identity_role_arn]

    content {
      sid    = "AllowTheIdentityFunctionToSignAndPublish"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions   = local.signing_actions
      resources = ["*"]
    }
  }
}

# The matching identity-side grant.
#
# A KMS key policy allows; an IAM policy on the principal is the other half. Both are needed for a
# call in the same account unless the key policy delegates to IAM, which the root statement above
# does. Attaching it explicitly rather than relying on that delegation keeps the function's own
# policy an honest description of what it can reach.
#
# Scoped to these keys' ARNs and to the same two actions the key policy grants, so neither half of
# the pair is wider than the other. A key added for a rotation joins both halves at once, because
# both are built from the same resource.
#
# The count reads var.attach_role_policies and not var.identity_role_name, for the same reason the
# MFA policy below reads the input variables rather than a computed ARN. A consumer passes
# module.lambda_domain["identity"].role_id, and when that role is itself still to be created its id
# is unknown at plan time. A count built from an unknown value is not a count Terraform can defer:
# it refuses to plan at all with Invalid count argument. The boolean is known by construction.
# identity_role_name must be non-null when the boolean is true, which variables.tf validates.
resource "aws_iam_role_policy" "identity_signing" {
  count = var.attach_role_policies ? 1 : 0

  name   = "identity-signing"
  role   = var.identity_role_name
  policy = local.signing_policy_json
}

# ---------------------------------------------------------------------------
# The MFA envelope key.
#
# SYMMETRIC_DEFAULT and ENCRYPT_DECRYPT, which is what GenerateDataKey needs. A separate key from
# the signing keys and not merely a separate alias: a key that can both sign tokens and decrypt
# TOTP seeds makes the blast radius of either compromise the whole of both, and the package refuses
# a data_key_arn equal to a signing key for that reason.
#
# The package never calls kms:Encrypt on this key. webbpulse.identity.crypto uses envelope
# encryption, so KMS mints a fresh 256 bit data key per seed through GenerateDataKey, AES-256-GCM
# happens locally, and only the wrapped key goes to KMS. That is why the grant below is
# GenerateDataKey and Decrypt rather than Encrypt and Decrypt: a fresh data key per secret makes
# GCM nonce reuse impossible by construction, and there is no call for Encrypt to serve.
#
# AUTOMATIC ROTATION IS ON HERE, the opposite of the signing keys, because the failure mode is
# opposite. The signing key's kid is derived from its material, so rotation orphans issued tokens.
# An envelope key has no such identifier: KMS retains every previous backing key and selects the
# right one from the wrapped blob, so a data key wrapped before a rotation still opens afterwards
# with nothing to re-encrypt.
# ---------------------------------------------------------------------------

resource "aws_kms_key" "identity_mfa" {
  count = var.enable_mfa_encryption_key ? 1 : 0

  description = "Symmetric envelope key for the ${var.name_prefix} identity function's TOTP seeds. Wraps a per-seed AES-256 data key through GenerateDataKey; the seed itself is encrypted locally with AES-256-GCM and never sent to KMS."

  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = var.mfa_encryption_key_rotation
  deletion_window_in_days  = var.mfa_encryption_key_deletion_window_in_days

  policy = coalesce(var.mfa_encryption_key_policy_json, local.generated_mfa_key_policy)

  tags = length(local.mfa_key_tags) == 0 ? null : local.mfa_key_tags
}

# Same purpose as the signing key's alias: a name that is a pure function of name_prefix, so a
# consumer can pass it where KMS accepts a key id without taking a resource reference on the key.
resource "aws_kms_alias" "identity_mfa" {
  count = var.enable_mfa_encryption_key && var.create_mfa_encryption_key_alias ? 1 : 0

  name          = local.mfa_key_alias
  target_key_id = aws_kms_key.identity_mfa[0].key_id
}

# The MFA key policy, built on the signing key policy's shape: an account root statement that is
# never optional, plus the identity role's two calls.
#
# The condition is the part worth reading. webbpulse.identity.crypto sends an encryption context of
# {"user_id": "<id>", "purpose": "totp"} on both GenerateDataKey and Decrypt, and KMS binds it into
# the wrapped key as authenticated additional data. Only `purpose` has a fixed value, so only
# `purpose` can be pinned: `user_id` is a different string per user and no static condition can
# express it. Pinning purpose still buys the real property, that this key is usable for TOTP seeds
# and nothing else, so a later feature wanting an envelope gets its own key rather than silently
# widening this one.
#
# kms:EncryptionContext:<context-key> is a single valued condition key, so StringEquals is correct
# and a set operator would not be: the AWS KMS condition key documentation says explicitly that
# using ForAllValues with it produces an overly permissive policy. Both operations support it.
data "aws_iam_policy_document" "mfa_key" {
  count = var.enable_mfa_encryption_key ? 1 : 0

  statement {
    sid    = "EnableIAMPoliciesInThisAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.identity_role_arn == null ? [] : [var.identity_role_arn]

    content {
      sid    = "AllowTheIdentityFunctionToSealAndOpenTotpSeeds"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions   = local.mfa_key_actions
      resources = ["*"]

      dynamic "condition" {
        for_each = var.mfa_encryption_context_purpose == null ? [] : [var.mfa_encryption_context_purpose]

        content {
          test     = "StringEquals"
          variable = "kms:EncryptionContext:purpose"
          values   = [condition.value]
        }
      }
    }
  }
}

# The matching identity-side grant, scoped to exactly this key and exactly the two calls the
# envelope makes. Both halves carry the same condition, so neither is wider than the other.
#
# The count is built from input variables rather than from local.mfa_key_arn, even though that local
# says the same thing more directly. A created key's ARN is unknown until apply, so a count reading
# it makes the instance count itself unknown and Terraform refuses to plan at all. The same argument
# rules out var.identity_role_name, which is usually a role id that is unknown while the role is
# still to be created. Both parts below are known at plan time and answer the same two questions:
# the consumer wants the policies, and there is a key, because the module creates one or the
# consumer supplied one.
resource "aws_iam_role_policy" "identity_mfa" {
  count = var.attach_role_policies && local.mfa_key_exists ? 1 : 0

  name   = "identity-mfa"
  role   = var.identity_role_name
  policy = local.mfa_policy_json
}
