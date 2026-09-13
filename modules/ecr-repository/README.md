# terraform-aws-ecr-repository

Creates a map of ECR repositories, one per domain function, with immutable commit-SHA tags, basic
scan on push, and a two-rule lifecycle policy that keeps storage flat. A repository policy is
written only when a cross-account principal is named.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/ecr-repository`.

## Usage

```hcl
module "registry" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ecr-repository"
  version = "~> 1.8"

  name_prefix = "example-production"

  repositories = {
    parts       = {}
    users       = {}
    build-lists = {}
  }
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `repositories` | Map of short domain key to per-repository overrides; `{}` takes every module-wide default | required |
| `name_prefix` | Prefix joined to each key with a slash to form the repository name; empty uses the key verbatim | `""` |
| `image_tag_mutability` | `IMMUTABLE` or `MUTABLE`; a repository can override | `"IMMUTABLE"` |
| `scan_on_push` | Basic scan on push, the free ECR scanner; a repository can override | `true` |
| `keep_last_tagged_images` | Tagged images kept by the second lifecycle rule; a repository can override | `10` |
| `expire_untagged_after_days` | Age in days at which an untagged image is expired; a repository can override | `1` |
| `tag_prefix_list` | Tag prefixes the "keep the last N" rule selects on; a repository can override | `["sha-"]` |
| `create_lifecycle_policy` | Create the lifecycle policy at all | `true` |
| `encryption_type` | `AES256`, `KMS` or `KMS_DSSE` | `"AES256"` |
| `encryption_kms_key` | KMS key ARN, only with a `KMS` or `KMS_DSSE` `encryption_type` | `null` |
| `force_delete` | Let Terraform delete a repository that still holds images; a repository can override | `false` |
| `repository_policy_principals` | IAM principal ARNs allowed to pull cross-account; empty creates no policy | `[]` |
| `repository_policy_json` | A complete repository policy applied to every repository, replacing the generated one | `null` |
| `tags` | Tags on every repository, on top of `default_tags`; empty is passed as `null` | `{}` |

Each entry in `repositories`, every field optional, `null` taking the module-wide value of the same
name:

```hcl
{
  image_tag_mutability       = optional(string)
  scan_on_push               = optional(bool)
  keep_last_tagged_images    = optional(number)
  expire_untagged_after_days = optional(number)
  tag_prefix_list            = optional(list(string))
  lifecycle_policy           = optional(string)
  force_delete               = optional(bool)
  tags                       = optional(map(string), {})
}
```

`lifecycle_policy` is a complete policy JSON document written verbatim, replacing the two generated
rules for that repository.

## Outputs

| Name | Description |
| --- | --- |
| `repositories` | Short key to `{ name, arn, url, registry_id }` for every repository created |
| `repository_urls` | Short key to repository URL; the map CI pushes to and `image_uri` is built from |
| `repository_arns` | Short key to repository ARN |
| `repository_arns_list` | Every repository ARN as a list sorted by key, for an IAM resource list |
| `repository_names` | Short key to full repository name, which is what an ECR API call takes |
| `registry_id` | The registry the repositories live in, which is the account id; `null` when the map is empty |

## Gotchas

- With keep-last-10 lifecycle rules a pinned bootstrap image tag can expire from ECR. The plan stays
  green and the apply fails, so refresh the bootstrap tag to the current head sha before an apply
  that replaces functions.
- A tagged image matching no prefix in `tag_prefix_list` is never selected by rule 2 and so is never
  expired. List every tag scheme in the repository, or the second one is never cleaned up.
- Encryption is fixed when a repository is created, so changing `encryption_type` or
  `encryption_kms_key` replaces every repository and destroys the images in them.
- `name` is force-new, so adopting an existing repository whose name does not already match
  `<name_prefix>/<key>` recreates it and loses every image. Adopt under `name_prefix = ""` instead.
- A same-account container-image Lambda needs no repository policy: Lambda writes the
  `LambdaECRImageRetrievalPolicy` statement itself on `CreateFunction`, provided the deploy role
  holds `ecr:GetRepositoryPolicy` and `ecr:SetRepositoryPolicy`. Setting
  `repository_policy_principals` makes Terraform own the whole document and drops that statement.
- Tag mutability is a repository-level setting, not a per-tag one, so an `IMMUTABLE` repository
  cannot also carry a moving `env-staging` pointer tag.
- Setting both `repository_policy_json` and `repository_policy_principals` fails at plan time,
  because only one of them can win.
- The repository and the function pulling from it must be in the same region. Lambda can pull
  cross-account but not cross-region.
- `create_lifecycle_policy = false` leaves repositories with no policy at all, so nothing is ever
  expired and storage grows with every push.
