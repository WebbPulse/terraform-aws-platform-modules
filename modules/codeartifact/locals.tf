locals {
  tier0_keys = toset([for k, r in var.repositories : k if length(r.upstreams) == 0])

  tier1_keys = toset([
    for k, r in var.repositories : k
    if length(r.upstreams) > 0 && alltrue([for u in r.upstreams : contains(local.tier0_keys, u)])
  ])

  tier2_keys = toset([
    for k, _ in var.repositories : k
    if !contains(local.tier0_keys, k) && !contains(local.tier1_keys, k)
  ])

  repositories = merge(
    aws_codeartifact_repository.tier0,
    aws_codeartifact_repository.tier1,
    aws_codeartifact_repository.tier2,
  )

  repository_arns = { for k, r in local.repositories : k => r.arn }

  reader_principals = sort(distinct(concat(
    [for a in var.reader_account_ids : "arn:aws:iam::${a}:root"],
    var.reader_principal_arns,
  )))

  has_readers    = length(local.reader_principals) > 0
  has_publishers = length(var.publisher_principal_arns) > 0

  store_keys = toset([for k, r in var.repositories : k if length(r.external_connections) > 0])

  publisher_repository_keys = sort(
    var.publisher_repository_keys != null
    ? var.publisher_repository_keys
    : [for k, _ in var.repositories : k if !contains(local.store_keys, k)]
  )

  publish_keys = toset(local.has_publishers ? local.publisher_repository_keys : [])

  policy_repository_keys = toset([
    for k, _ in var.repositories : k
    if local.has_readers || contains(local.publish_keys, k)
  ])

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
      Resource  = "*"
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
    Resource  = "*"
  }

  package_scoped_publish_actions = toset([
    "codeartifact:PublishPackageVersion",
    "codeartifact:PutPackageMetadata",
  ])

  publish_package_actions = sort([
    for a in distinct(var.publisher_repository_actions) : a
    if contains(local.package_scoped_publish_actions, a)
  ])

  publish_repository_actions = sort([
    for a in distinct(var.publisher_repository_actions) : a
    if !contains(local.package_scoped_publish_actions, a)
  ])

  repository_publish_statements = {
    for k in local.publish_keys : k => concat(
      length(local.publish_package_actions) > 0 ? [{
        Sid       = "Publish"
        Effect    = "Allow"
        Principal = { AWS = local.publisher_principal_value }
        Action    = local.publish_package_actions
        Resource  = "${replace(local.repository_arns[k], ":repository/", ":package/")}/*"
      }] : [],
      length(local.publish_repository_actions) > 0 ? [{
        Sid       = "PublishRepositoryAccess"
        Effect    = "Allow"
        Principal = { AWS = local.publisher_principal_value }
        Action    = local.publish_repository_actions
        Resource  = "*"
      }] : [],
    )
  }

  repository_policy_json = {
    for k in local.policy_repository_keys : k => jsonencode({
      Version = "2012-10-17"
      Statement = [
        for statement in concat(
          local.has_readers ? [jsonencode(local.repository_read_statement)] : [],
          contains(local.publish_keys, k) ? [for s in local.repository_publish_statements[k] : jsonencode(s)] : [],
        ) : jsondecode(statement)
      ]
    })
  }

  endpoint_keys = {
    for pair in setproduct(keys(var.repositories), var.endpoint_formats) :
    "${pair[0]}:${pair[1]}" => { repository = pair[0], format = pair[1] }
  }
}
