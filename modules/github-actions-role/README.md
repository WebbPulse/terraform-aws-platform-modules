# terraform-aws-github-actions-role

The IAM role a repository's GitHub Actions workflows assume to deploy, trusted through GitHub's
OIDC provider so no long-lived AWS keys live in GitHub. One inline policy carries the deploy
permissions, and the module can create the account-level OIDC provider or trust one that exists.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role`.

## Usage

```hcl
module "github_actions_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 1.4"

  role_name = "${local.prefix}-github-actions-deploy"
  subjects  = ["repo:WebbPulse/ExampleRepo:*"]

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
| `subjects` | GitHub OIDC `sub` claims allowed to assume the role, matched with `StringLike` | required |
| `audience` | Required `aud` claim and the created provider's client id | `"sts.amazonaws.com"` |
| `create_oidc_provider` | Create the account's `token.actions.githubusercontent.com` provider | `true` |
| `oidc_provider_arn` | Existing provider ARN, required when `create_oidc_provider` is false | `null` |
| `oidc_thumbprints` | Thumbprints on the created provider; informational since 2023 | the two GitHub thumbprints |
| `inline_policy_name` | Name of the single inline policy carrying `policy_statements` | `"deploy-permissions"` |
| `policy_statements` | Statements of the inline deploy policy; empty creates no inline policy | `[]` |

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
- An AWS account holds at most one OIDC provider per URL. The second stack in the same account
  must set `create_oidc_provider = false` and pass `oidc_provider_arn`, or the apply fails with
  EntityAlreadyExists.
- Every statement needs exactly one of `actions` or `not_actions` and exactly one of `resources`
  or `not_resources`; IAM rejects a statement carrying both forms. Use `"*"` for actions with no
  resource-level permissions.
- One-or-many fields render as a bare JSON string when they hold exactly one element and as a list
  otherwise, matching hand-written policy documents.
- One inline policy only, subject to the 10240-character inline limit; attach managed policies
  from outside using `role_name`. The GitHub side (`AWS_DEPLOY_ROLE_ARN`, `id-token: write`) is
  the consumer's to set.
