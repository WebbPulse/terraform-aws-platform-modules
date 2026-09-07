locals {
  # Upstream ordering. An aws_codeartifact_repository with an upstream block fails to create if the
  # upstream repository does not exist yet, and Terraform cannot see that dependency: the upstream
  # is named by a plain string, not by a reference to the other instance of the same resource. A
  # for_each resource also cannot depend on itself, so one resource cannot be ordered against
  # another instance of itself.
  #
  # The fix is explicit tiers, one resource per tier, each depending on the one below. Tier 0 is
  # every repository with no upstreams, which is where the external-connection stores live. Tier 1
  # upstreams only into tier 0. Tier 2 upstreams into tier 0 or tier 1. A validation on the
  # repositories variable rejects anything deeper, so these three tiers cover every allowed shape.
  tier0_keys = toset([for k, r in var.repositories : k if length(r.upstreams) == 0])

  tier1_keys = toset([
    for k, r in var.repositories : k
    if length(r.upstreams) > 0 && alltrue([for u in r.upstreams : contains(local.tier0_keys, u)])
  ])

  tier2_keys = toset([
    for k, _ in var.repositories : k
    if !contains(local.tier0_keys, k) && !contains(local.tier1_keys, k)
  ])

  # Every repository from all three tiers back in one map, so the rest of the module never has to
  # care which tier a repository landed in.
  repositories = merge(
    aws_codeartifact_repository.tier0,
    aws_codeartifact_repository.tier1,
    aws_codeartifact_repository.tier2,
  )

  repository_arns = { for k, r in local.repositories : k => r.arn }

  # Reader principals: whole accounts named by their root ARN, plus any specific principal ARNs.
  # Sorted so a reordered input variable does not show up as a policy diff.
  reader_principals = sort(distinct(concat(
    [for a in var.reader_account_ids : "arn:aws:iam::${a}:root"],
    var.reader_principal_arns,
  )))

  has_readers    = length(local.reader_principals) > 0
  has_publishers = length(var.publisher_principal_arns) > 0

  # Repositories publishers may write to. Never a store repository: a first-party package published
  # into the repository that proxies PyPI would shadow the public package of the same name for
  # every consumer downstream of it.
  store_keys = toset([for k, r in var.repositories : k if length(r.external_connections) > 0])

  publisher_repository_keys = sort(
    var.publisher_repository_keys != null
    ? var.publisher_repository_keys
    : [for k, _ in var.repositories : k if !contains(local.store_keys, k)]
  )

  # A repository gets a publish statement only when there is somebody to grant it to and the
  # repository is one of the internal ones.
  publish_keys = toset(local.has_publishers ? local.publisher_repository_keys : [])

  # Repositories that end up with a policy at all. A repository nobody reads and nobody publishes to
  # gets no aws_codeartifact_repository_permissions_policy, rather than an empty one, because
  # policy_document is a required argument and a policy with no statements is invalid.
  policy_repository_keys = toset([
    for k, _ in var.repositories : k
    if local.has_readers || contains(local.publish_keys, k)
  ])

  # IAM accepts a bare string where a list holds one element, and that is how hand-written policies
  # are usually written. Rendering the same keeps a policy that replaces a hand-written one
  # byte-identical in state. jsondecode of a jsonencode is the only way to write one expression that
  # yields either a string or a list, which is why every one-or-many field goes through the pair.
  reader_principal_value = jsondecode(
    length(local.reader_principals) == 1
    ? jsonencode(local.reader_principals[0])
    : jsonencode(local.reader_principals)
  )

  publisher_principals = sort(distinct(var.publisher_principal_arns))

  publisher_principal_value = jsondecode(
    length(local.publisher_principals) == 1
    ? jsonencode(local.publisher_principals[0])
    : jsonencode(local.publisher_principals)
  )

  domain_reader_statement = merge(
    var.domain_policy_sid == null ? {} : { Sid = var.domain_policy_sid },
    {
      Effect    = "Allow"
      Principal = { AWS = local.reader_principal_value }
      Action    = sort(distinct(var.reader_domain_actions))
      # The domain policy is evaluated for the domain and every resource inside it, so "*" here
      # means "everything in this domain", not "everything in the account".
      Resource = "*"
    },
  )

  domain_policy_json = var.domain_policy_document != null ? var.domain_policy_document : jsonencode({
    Version   = "2012-10-17"
    Statement = [local.domain_reader_statement]
  })

  create_domain_policy = var.domain_policy_document != null || local.has_readers

  repository_read_statement = {
    Sid       = "Read"
    Effect    = "Allow"
    Principal = { AWS = local.reader_principal_value }
    Action    = sort(distinct(var.reader_repository_actions))
    # A repository policy is only ever evaluated against the repository it is attached to, so the
    # resource is implied and the user guide's own examples set it to "*".
    Resource = "*"
  }

  repository_publish_statement = {
    Sid       = "Publish"
    Effect    = "Allow"
    Principal = { AWS = local.publisher_principal_value }
    Action    = sort(distinct(var.publisher_repository_actions))
    Resource  = "*"
  }

  # concat unifies the types of the elements it is given. The read and publish statements are the
  # same shape except for Principal.AWS, which is a string or a list of strings on the read side and,
  # when the publisher ARNs are unknown at plan time, an unknown of no settled type on the publish
  # side. Those two do not unify, and cty panics inside concat rather than degrading to an unknown
  # statement. Any caller that wires a role's ARN into publisher_principal_arns hits it; the
  # examples pass literals, which is why the module shipped green.
  #
  # Encoding each statement to a JSON string before the concat means concat only ever unifies
  # strings, which always works. Each element is decoded straight back afterwards, so the rendered
  # policy is byte-identical to what the object form produced.
  repository_policy_json = {
    for k in local.policy_repository_keys : k => jsonencode({
      Version = "2012-10-17"
      Statement = [
        for statement in concat(
          local.has_readers ? [jsonencode(local.repository_read_statement)] : [],
          contains(local.publish_keys, k) ? [jsonencode(local.repository_publish_statement)] : [],
        ) : jsondecode(statement)
      ]
    })
  }

  # One endpoint lookup per repository and format. The data source resolves a URL for any format
  # against any repository, so the product is well defined even where a repository holds no packages
  # of that format yet.
  endpoint_keys = {
    for pair in setproduct(keys(var.repositories), var.endpoint_formats) :
    "${pair[0]}:${pair[1]}" => { repository = pair[0], format = pair[1] }
  }
}
