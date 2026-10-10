locals {
  oidc_provider_url = "https://token.actions.githubusercontent.com"
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.this[0].arn : var.oidc_provider_arn

  trust_subjects = jsondecode(length(var.subjects) == 1 ? jsonencode(var.subjects[0]) : jsonencode(var.subjects))

  policy_statements = [
    for s in var.policy_statements : merge(
      { Effect = s.effect },
      s.actions == null ? {} : { Action = jsondecode(length(s.actions) == 1 ? jsonencode(s.actions[0]) : jsonencode(s.actions)) },
      s.not_actions == null ? {} : { NotAction = jsondecode(length(s.not_actions) == 1 ? jsonencode(s.not_actions[0]) : jsonencode(s.not_actions)) },
      s.resources == null ? {} : { Resource = jsondecode(length(s.resources) == 1 ? jsonencode(s.resources[0]) : jsonencode(s.resources)) },
      s.not_resources == null ? {} : { NotResource = jsondecode(length(s.not_resources) == 1 ? jsonencode(s.not_resources[0]) : jsonencode(s.not_resources)) },
      s.sid == null ? {} : { Sid = s.sid },
      s.condition == null ? {} : {
        Condition = {
          for op, kv in s.condition : op => {
            for k, v in kv : k => jsondecode(length(v) == 1 ? jsonencode(v[0]) : jsonencode(v))
          }
        }
      },
    )
  ]

  lambda_deploy_actions = [
    "lambda:UpdateFunctionCode",
    "lambda:PublishVersion",
    "lambda:GetFunction",
    "lambda:GetFunctionConfiguration",
    "lambda:GetFunctionCodeSigningConfig",
  ]

  ecr_push_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:InitiateLayerUpload",
    "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload",
    "ecr:PutImage",
    "ecr:BatchGetImage",
    "ecr:DescribeImages",
    "ecr:GetDownloadUrlForLayer",
    "ecr:GetRepositoryPolicy",
  ]

  ecr_pull_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:DescribeImages",
    "ecr:GetDownloadUrlForLayer",
  ]

  spa_sync_actions = [
    "s3:PutObject",
    "s3:GetObject",
    "s3:DeleteObject",
    "s3:ListBucket",
  ]

  lambda_invoke_function_arns = var.lambda_image_deploy == null ? [] : (
    var.lambda_image_deploy.invoke_function_arns == null ? var.lambda_image_deploy.function_arns : var.lambda_image_deploy.invoke_function_arns
  )

  preset_statement_inputs = concat(
    var.lambda_image_deploy == null ? [] : [
      {
        sid       = "LambdaImageDeploy"
        actions   = tolist(local.lambda_deploy_actions)
        resources = tolist(var.lambda_image_deploy.function_arns)
      },
    ],
    length(local.lambda_invoke_function_arns) == 0 ? [] : [
      {
        sid       = "LambdaSmokeInvoke"
        actions   = tolist(["lambda:InvokeFunction"])
        resources = tolist(local.lambda_invoke_function_arns)
      },
    ],
    var.ecr_push == null ? [] : [
      {
        sid       = "EcrAuth"
        actions   = tolist(["ecr:GetAuthorizationToken"])
        resources = tolist(["*"])
      },
      {
        sid       = "EcrPush"
        actions   = tolist(local.ecr_push_actions)
        resources = tolist(var.ecr_push.repository_arns)
      },
    ],
    var.ecr_push == null ? [] : length(var.ecr_push.pull_repository_arns) == 0 ? [] : [
      {
        sid       = "EcrPull"
        actions   = tolist(local.ecr_pull_actions)
        resources = tolist(var.ecr_push.pull_repository_arns)
      },
    ],
    var.spa_deploy == null ? [] : [
      {
        sid       = "SpaSync"
        actions   = tolist(local.spa_sync_actions)
        resources = tolist(flatten([for arn in var.spa_deploy.bucket_arns : [arn, "${arn}/*"]]))
      },
    ],
    var.spa_deploy == null ? [] : length(var.spa_deploy.distribution_arns) == 0 ? [] : [
      {
        sid       = "SpaInvalidate"
        actions   = tolist(["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"])
        resources = tolist(var.spa_deploy.distribution_arns)
      },
    ],
  )

  preset_statements = [
    for s in local.preset_statement_inputs : {
      Sid      = s.sid
      Effect   = "Allow"
      Action   = jsondecode(length(s.actions) == 1 ? jsonencode(s.actions[0]) : jsonencode(s.actions))
      Resource = jsondecode(length(s.resources) == 1 ? jsonencode(s.resources[0]) : jsonencode(s.resources))
    }
  ]

  all_policy_statements = concat(local.policy_statements, local.preset_statements)

  all_statement_sids = concat(
    compact([for s in var.policy_statements : s.sid == null ? "" : s.sid]),
    [for s in local.preset_statement_inputs : s.sid],
  )

  tags = length(var.tags) > 0 ? var.tags : null
}
