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
resource "aws_iam_role_policy" "identity_signing" {
  count = var.identity_role_name == null ? 0 : 1

  name   = "identity-signing"
  role   = var.identity_role_name
  policy = local.signing_policy_json
}
