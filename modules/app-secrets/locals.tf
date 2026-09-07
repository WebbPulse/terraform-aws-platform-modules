locals {
  # Full Secrets Manager name of each secret: an explicit name wins, otherwise the map key behind
  # the prefix. An empty prefix leaves the key as the whole name.
  secret_names = {
    for k, s in var.secrets :
    k => s.name != null ? s.name : (var.name_prefix == "" ? k : "${var.name_prefix}${var.name_separator}${k}")
  }

  # Which secrets get a random_password. Split out so the generator resource exists only for those
  # keys and a secret that switches away from generate destroys its password rather than keeping a
  # dangling one.
  generated_keys = toset([for k, s in var.secrets : k if s.generate])

  # Which secrets Terraform manages a version for, and what string each stores. A secret with no
  # source of a value is absent from this map unless create_empty_version says otherwise, so no
  # version resource is created and the first put-secret-value out of band becomes version 1.
  #
  # An empty string in `value` counts as no value rather than as a version holding "". Secrets
  # Manager has no empty version, and the shape this serves is an optional secret wired to an
  # optional variable: the secret is created either way so the application's IAM grant is stable,
  # and the version appears only once the variable is set.
  #
  # nonsensitive() is applied to the boolean, not to any value: for_each keys cannot be derived
  # from a sensitive value, and "does this secret have a value at all" is a fact about the
  # configuration rather than the secret itself. No secret material reaches a resource key, an
  # output or the plan text through it.
  has_version = {
    for k, s in var.secrets :
    k => nonsensitive(s.generate || (s.value != null && s.value != "") || s.json != null || s.placeholder != null || var.create_empty_version)
  }

  version_strings = {
    for k, s in var.secrets :
    k => (
      s.generate ? random_password.this[k].result :
      s.value != null ? s.value :
      s.json != null ? jsonencode({ for jk, jv in s.json : jk => jv if jv != null }) :
      s.placeholder != null ? s.placeholder :
      ""
    )
    if local.has_version[k]
  }

  # Placeholder secrets carry lifecycle.ignore_changes on the stored string, so they live in their
  # own resource: ignore_changes takes a literal, not an expression, and cannot be switched per
  # instance of one resource.
  placeholder_keys = toset([for k, s in var.secrets : k if s.placeholder != null])
  managed_keys     = toset([for k, _ in local.version_strings : k if !contains(local.placeholder_keys, k)])

  # Every secret's ARN in one map regardless of which resource owns its versions.
  secret_arns = { for k, r in aws_secretsmanager_secret.this : k => r.arn }

  policy_keys = var.policy_secret_keys == null ? keys(var.secrets) : var.policy_secret_keys
  policy_resources = sort([
    for k in local.policy_keys : aws_secretsmanager_secret.this[k].arn
  ])

  # IAM accepts a bare string where a list holds one element, and hand-written policies are usually
  # written that way. Rendering the same keeps a policy that replaces one byte-identical in state.
  # jsondecode of a jsonencode is the only way to write one expression that yields either a string
  # or a list, so both one-or-many fields go through the same pair.
  policy_statement = merge(
    var.policy_sid == null ? {} : { Sid = var.policy_sid },
    {
      Effect   = "Allow"
      Action   = jsondecode(length(var.policy_actions) == 1 ? jsonencode(var.policy_actions[0]) : jsonencode(var.policy_actions))
      Resource = jsondecode(length(local.policy_resources) == 1 ? jsonencode(local.policy_resources[0]) : jsonencode(local.policy_resources))
    },
  )

  read_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.policy_statement]
  })
}
