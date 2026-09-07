# terraform-aws-github-actions-role

The IAM role a repository's GitHub Actions workflows assume to deploy, trusted through GitHub's
OIDC provider so no long-lived AWS keys live in GitHub. One inline policy carries the deploy
permissions; the module owns nothing else, and it can create the account-level OIDC provider or
trust one that already exists.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role`.
Both application estates were carrying this by hand in `terraform/iam_github_actions.tf`; the
module reproduces those resources exactly so that adopting it is three `moved` blocks and an
empty plan. See [Adoption](#adoption).

## How it works

```
GitHub Actions job (permissions: id-token: write)
  │  aws-actions/configure-aws-credentials
  │    role-to-assume = <role_arn>, audience = sts.amazonaws.com
  ▼
sts:AssumeRoleWithWebIdentity
  ├─ Principal  : IAM OIDC provider for token.actions.githubusercontent.com  (one per account)
  ├─ StringEquals aud = audience
  └─ StringLike   sub in subjects          e.g. repo:WebbPulse/CarModPicker:*
  ▼
aws_iam_role <role_name>
  └─ aws_iam_role_policy <inline_policy_name>   the statements in policy_statements
```

- **OIDC provider.** `aws_iam_openid_connect_provider` for `https://token.actions.githubusercontent.com`
  with `client_id_list = [audience]`. An AWS account holds at most one provider per URL, so the
  first stack in an account creates it (`create_oidc_provider = true`, the default) and any other
  stack in the same account passes `create_oidc_provider = false` and the provider's ARN.
- **Trust policy.** A single statement: `sts:AssumeRoleWithWebIdentity` from the provider, the
  `aud` claim equal to `audience`, and the `sub` claim matched with `StringLike` against
  `subjects`. `repo:ORG/REPO:*` admits every workflow in the repository;
  `repo:ORG/REPO:environment:production` admits only jobs bound to that GitHub environment;
  `repo:ORG/REPO:ref:refs/heads/main` admits only pushes to `main`. GitHub also issues the
  rename-proof form `repo:ORG@ORG_ID/REPO@REPO_ID:...` when the repository is configured for it.
- **Permissions.** `policy_statements` is rendered into one inline policy. Statements are plain
  objects (`actions` or `not_actions`, `resources` or `not_resources`, optional `sid`, `effect`,
  `condition`) so the consumer keeps
  its statements next to the resources they name, with real ARN references, and the module never
  has to know what a frontend bucket is. Managed policy attachments and extra inline policies can
  be added from outside with `role_name`.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `role_name` | Full role name, e.g. `carmodpicker-production-github-actions-deploy` | required |
| `subjects` | `sub` claims allowed to assume the role, `StringLike` matched | required |
| `policy_statements` | List of `{ actions \| not_actions, resources \| not_resources, sid?, effect?, condition? }` for the inline policy; empty creates none | `[]` |
| `inline_policy_name` | Name of the inline policy | `deploy-permissions` |
| `audience` | Required `aud` claim and the provider's client id | `sts.amazonaws.com` |
| `create_oidc_provider` | Create the account's `token.actions.githubusercontent.com` provider here | `true` |
| `oidc_provider_arn` | Existing provider ARN, required when `create_oidc_provider` is `false` | `null` |
| `oidc_thumbprints` | Thumbprint list on the created provider (informational since 2023) | the two GitHub thumbprints |
| `role_path` | IAM path | `/` |
| `role_description` | Role description | `null` |
| `max_session_duration` | Seconds, 3600 to 43200 | `3600` |
| `permissions_boundary_arn` | Permissions boundary on the role | `null` |
| `tags` | Extra tags on the role and created provider, on top of `default_tags` | `{}` |

`condition` is `operator -> key -> list of values`, for example
`{ StringEquals = { "aws:ResourceTag/Project" = ["carmodpicker"] } }`.

## Outputs

| Name | Description |
| --- | --- |
| `role_arn` | Role ARN; set it as `AWS_DEPLOY_ROLE_ARN` on the GitHub environment |
| `role_name` | Role name, for attachments made outside the module |
| `oidc_provider_arn` | ARN of the provider the role trusts, created or passed in |

## Rendering guarantees

IAM accepts a bare string where a list has one element, and both estates were written with
`jsonencode()` of hand-built maps that used a string for a single value and a list otherwise. The
module renders the same way, and it applies the rule to every one-or-many field rather than to
some of them: one subject is a string, several are a list, and the same holds for `Action`,
`NotAction`, `Resource`, `NotResource` and each condition key's values. `Sid`, `Condition` and the
`Not` forms are present only when given. Combined with `jsonencode()`'s sorted keys, the trust
policy and the inline policy come out byte-identical to what is in state, so the plan after the
`moved` blocks is empty rather than relying on the provider's semantic policy comparison (which
would also hide the difference, but would leave the stored document unchanged until the next real
edit).

A statement whose `actions` holds one entry therefore renders as `"Action": "ssm:GetParameter"`,
not `"Action": ["ssm:GetParameter"]`, which is what both estates have in state today.

`tags = {}` is passed to the provider as `null`, which is the same as omitting the argument; the
role and the provider then carry `default_tags` only, exactly as today.

## Adoption

Both estates follow the same recipe. Replace the contents of `terraform/iam_github_actions.tf`
with the module block and the `moved` blocks below, and repoint any output that referenced the
old resources. The role ARN does not change, so the `AWS_DEPLOY_ROLE_ARN` GitHub variable and the
workflows stay as they are. Land it on `staging` first and read the speculative plan: it must
show only the moves, `0 to add, 0 to change, 0 to destroy`.

The module ships from 1.2.0; the single-value rendering fix and the not_actions / not_resources fields land in 1.4.0, so consumers need `version = "~> 1.4"`.

### CarModPicker

```hcl
module "github_actions_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 1.4"

  role_name = "${local.prefix}-github-actions-deploy"
  subjects  = ["repo:WebbPulse/CarModPicker:*"]

  policy_statements = [
    # Lambda: upload the zip to the artifacts bucket, then point the function at it
    {
      actions   = ["s3:PutObject", "s3:GetObject"]
      resources = ["${aws_s3_bucket.lambda_artifacts.arn}/*"]
    },
    {
      actions = [
        "lambda:UpdateFunctionCode",
        "lambda:PublishVersion",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:GetFunctionCodeSigningConfig",
      ]
      resources = [aws_lambda_function.api.arn]
    },
    # S3: sync frontend build artifacts
    {
      actions = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.frontend.arn,
        "${aws_s3_bucket.frontend.arn}/*",
      ]
    },
    # CloudFront: invalidate the cache after a frontend deploy
    {
      actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
      resources = [aws_cloudfront_distribution.frontend.arn]
    },
  ]
}

moved {
  from = aws_iam_openid_connect_provider.github_actions
  to   = module.github_actions_role.aws_iam_openid_connect_provider.this[0]
}

moved {
  from = aws_iam_role.github_actions_deploy
  to   = module.github_actions_role.aws_iam_role.this
}

moved {
  from = aws_iam_role_policy.github_actions_deploy
  to   = module.github_actions_role.aws_iam_role_policy.this[0]
}
```

In `outputs.tf`, `github_actions_role_arn` becomes `module.github_actions_role.role_arn`. The
statement order above is the order in the current file; keep it so the rendered document stays
byte-identical.

### WebbPulse-Portfolio

```hcl
module "github_actions_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 1.4"

  role_name = "${local.prefix}-github-actions-deploy"
  subjects  = ["repo:WebbPulse@185014056/WebbPulse-Portfolio@1029410045:*"]

  policy_statements = [
    {
      actions = [
        "lambda:UpdateFunctionCode",
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:PublishVersion",
      ]
      resources = [aws_lambda_function.api.arn]
    },
    {
      actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      resources = [aws_s3_bucket.lambda_artifacts.arn, "${aws_s3_bucket.lambda_artifacts.arn}/*"]
    },
    {
      actions = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      resources = [
        aws_s3_bucket.frontend.arn,
        "${aws_s3_bucket.frontend.arn}/*",
      ]
    },
    {
      actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
      resources = [aws_cloudfront_distribution.frontend.arn]
    },
  ]
}

moved {
  from = aws_iam_openid_connect_provider.github_actions
  to   = module.github_actions_role.aws_iam_openid_connect_provider.this[0]
}

moved {
  from = aws_iam_role.github_actions_deploy
  to   = module.github_actions_role.aws_iam_role.this
}

moved {
  from = aws_iam_role_policy.github_actions_deploy
  to   = module.github_actions_role.aws_iam_role_policy.this[0]
}
```

The Portfolio file also carries an `import` block that adopted the production account's
pre-existing OIDC provider. That import has already happened, so the block is a no-op; either
delete it or, to keep it working for a fresh account, point it at the new address:

```hcl
import {
  for_each = var.environment == "production" ? toset(["production"]) : toset([])
  to       = module.github_actions_role.aws_iam_openid_connect_provider.this[0]
  id       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}
```

### What the module reproduces, attribute by attribute

| Attribute | Today | Module |
| --- | --- | --- |
| Provider `url`, `client_id_list`, `thumbprint_list` | `https://token.actions.githubusercontent.com`, `["sts.amazonaws.com"]`, the two GitHub thumbprints | same, from `audience` and the `oidc_thumbprints` default |
| Role `name` | `<project>-<environment>-github-actions-deploy` | `role_name` |
| Role `path`, `description`, `max_session_duration`, `permissions_boundary` | `/`, none, 3600, none | defaults |
| Role and provider `tags` | none beyond `default_tags` | `tags = {}` becomes `null` |
| Trust policy | one statement, `StringEquals` aud, `StringLike` sub as a string | identical JSON |
| Inline policy | `aws_iam_role_policy` named `deploy-permissions`, `Effect`/`Action`/`Resource` only | identical JSON given the same statement order |

## Known limits

- One inline policy. A role that needs more than the 10240-character inline limit attaches
  managed policies from outside with `role_name`.
- One trust statement. Trusting a second identity provider (a different GitHub Enterprise
  issuer, or an AWS principal) is a different role.
- The module does not touch the GitHub side. `AWS_DEPLOY_ROLE_ARN` on the GitHub environment and
  `permissions: id-token: write` on the workflow are the consumer's to set.
