# terraform-aws-github-actions-role

The IAM role a repository's GitHub Actions workflows assume to deploy, trusted through GitHub's
OIDC provider so no long-lived AWS keys live in GitHub. One inline policy carries the deploy
permissions, and the module can create the account-level OIDC provider or trust one that exists.

Consumed as `terraform.webbpulse.com/WebbPulse/platform-modules/aws//modules/github-actions-role`.

## Usage

```hcl
module "github_actions_role" {
  source  = "terraform.webbpulse.com/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.38"

  role_name = "${local.prefix}-github-actions-deploy"
  subjects  = ["repo:WebbPulse/ExampleRepo:environment:production"]

  policy_statements = [
    {
      actions   = ["s3:PutObject", "s3:GetObject"]
      resources = ["${aws_s3_bucket.artifacts.arn}/*"]
    },
  ]
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `role_name` | Full role name, taken as-is; a rename replaces the role | required |
| `role_path` | IAM path of the role; changing it replaces the role | `"/"` |
| `role_description` | Description shown on the IAM role | `null` |
| `max_session_duration` | Maximum session duration in seconds, 3600 to 43200 | `3600` |
| `permissions_boundary_arn` | ARN of a permissions boundary policy to set on the role | `null` |
| `tags` | Tags on the role and, when created here, the OIDC provider | `{}` |
| `subjects` | GitHub OIDC `sub` claims allowed to assume the role, matched with `StringLike`; `*` and `?` rejected unless `allow_wildcard_subjects` | required |
| `allow_wildcard_subjects` | Accept `*` and `?` in `subjects` | `false` |
| `audience` | Required `aud` claim and the created provider's client id | `"sts.amazonaws.com"` |
| `create_oidc_provider` | Create the account's `token.actions.githubusercontent.com` provider | `true` |
| `oidc_provider_arn` | Existing provider ARN, required when `create_oidc_provider` is false | `null` |
| `oidc_thumbprints` | Thumbprints on the created provider; informational since 2023 | the two GitHub thumbprints |
| `inline_policy_name` | Name of the single inline policy carrying `policy_statements` | `"deploy-permissions"` |
| `policy_statements` | Statements of the inline deploy policy; empty creates no inline policy | `[]` |
| `lambda_image_deploy` | Preset: `{ function_arns, invoke_function_arns }` for image deploys and a smoke invoke | `null` |
| `ecr_push` | Preset: `{ repository_arns, pull_repository_arns }` for ECR auth, push and base image pull | `null` |
| `spa_deploy` | Preset: `{ bucket_arns, distribution_arns }` for an S3 sync and CloudFront invalidation | `null` |

Each `policy_statements` entry is an object:

```hcl
{
  sid           = optional(string)
  effect        = optional(string, "Allow")
  actions       = optional(list(string))
  not_actions   = optional(list(string))
  resources     = optional(list(string))
  not_resources = optional(list(string))
  condition     = optional(map(map(list(string))))  # operator -> key -> values
}
```

The presets append fixed statements after `policy_statements` in the same inline policy:

| Preset | Sid | Grants |
| --- | --- | --- |
| `lambda_image_deploy` | `LambdaImageDeploy` | `lambda:UpdateFunctionCode`, `PublishVersion`, `GetFunction`, `GetFunctionConfiguration`, `GetFunctionCodeSigningConfig` on `function_arns` |
| `lambda_image_deploy` | `LambdaSmokeInvoke` | `lambda:InvokeFunction` on `invoke_function_arns`; null reuses `function_arns`, `[]` drops the statement |
| `ecr_push` | `EcrAuth` | `ecr:GetAuthorizationToken` on `*` |
| `ecr_push` | `EcrPush` | layer upload, `PutImage`, `BatchGetImage`, `DescribeImages`, `GetDownloadUrlForLayer`, `GetRepositoryPolicy` on `repository_arns` |
| `ecr_push` | `EcrPull` | `BatchCheckLayerAvailability`, `BatchGetImage`, `DescribeImages`, `GetDownloadUrlForLayer` on `pull_repository_arns`, omitted when empty |
| `spa_deploy` | `SpaSync` | `s3:PutObject`, `GetObject`, `DeleteObject`, `ListBucket` on each bucket and `<bucket>/*` |
| `spa_deploy` | `SpaInvalidate` | `cloudfront:CreateInvalidation`, `GetInvalidation` on `distribution_arns`, omitted when empty |

## Outputs

| Name | Description |
| --- | --- |
| `role_arn` | Role ARN; set it as `AWS_DEPLOY_ROLE_ARN` on the GitHub environment |
| `role_name` | Role name, for attachments made outside the module |
| `oidc_provider_arn` | ARN of the provider the role trusts, created or passed in |

## Gotchas

- Newer repositories get immutable OIDC subjects of the form
  `repo:WebbPulse@<org-id>/<repo>@<repo-id>`. Read the org's `sub_claim_prefix` before writing a
  trust policy rather than assuming the `repo:OWNER/NAME` form.
- Since 2.38.0 `subjects` rejects `*` and `?`. `repo:ORG/REPO:*` trusts every workflow on every
  branch and pull request, so a deploy role should name `environment:<env>` or
  `ref:refs/heads/<branch>` claims. A role that already trusts a wildcard keeps its trust policy
  unchanged by setting `allow_wildcard_subjects = true`.
- An AWS account holds at most one OIDC provider per URL. The second stack in the same account
  must set `create_oidc_provider = false` and pass `oidc_provider_arn`, or the apply fails with
  EntityAlreadyExists.
- Every statement needs exactly one of `actions` or `not_actions` and exactly one of `resources`
  or `not_resources`; IAM rejects a statement carrying both forms. Use `"*"` for actions with no
  resource-level permissions.
- One-or-many fields render as a bare JSON string when they hold exactly one element and as a list
  otherwise, matching hand-written policy documents.
- The presets only add permission statements. They never touch `subjects`, the trust policy, or
  the wildcard check, so a role keeps the immutable `repo:WebbPulse@<org-id>/<repo>@<repo-id>` subject
  it already trusts.
- **Adopting a preset rewrites the policy text, not the role.** The preset sids replace the hand
  written ones (`EcrPushDomainImages` becomes `EcrPush`, `SharedBaseImagePull` becomes `EcrPull`), so
  the adoption plan is one in place update of `deploy-permissions` and nothing else. A
  `policy_statements` sid that matches a preset sid fails the plan with a precondition naming both,
  because IAM requires sids to be unique in a policy.
- `ecr_push` deliberately leaves out `ecr:SetRepositoryPolicy`: a deploy role that can rewrite the
  repository policy can grant itself, or anyone, pull and push. Keep it in `policy_statements` only
  if a workflow really sets the policy.
- `lambda_image_deploy` takes unqualified function ARNs. A `lambda:InvokeFunction` grant on the
  unqualified ARN covers `$LATEST` only, which is what a post deploy smoke invoke calls.
- One inline policy only, subject to the 10240-character inline limit; attach managed policies
  from outside using `role_name`. The GitHub side (`AWS_DEPLOY_ROLE_ARN`, `id-token: write`) is
  the consumer's to set.
