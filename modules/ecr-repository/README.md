# terraform-aws-ecr-repository

An application's container registry as one module block: a map of ECR repositories, one per domain
function, with immutable commit-SHA tags, basic scan on push, and a two-rule lifecycle policy that
keeps storage flat. One `aws_ecr_repository` per entry, keyed by the short domain name the
application knows the image by, so a new domain is one more entry in a map.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/ecr-repository`.
The Lambda functions that pull these images, the CI role that pushes to them, and any IAM
attachment stay with the consumer; the module hands back the URLs, names and ARNs they need.

## How it works

```
var.repositories  =  { <domain key> = { image_tag_mutability?, scan_on_push?,
                                        keep_last_tagged_images?, expire_untagged_after_days?,
                                        tag_prefix_list?, lifecycle_policy?, force_delete?, tags? } }
   │
   │  name = "<name_prefix>/<key>"
   ▼
aws_ecr_repository.this[<key>]
   ├─ image_tag_mutability          IMMUTABLE by default, per-repository override
   ├─ image_scanning_configuration  scan_on_push, basic scanning, free
   ├─ encryption_configuration      AES256 by default, KMS with a key when asked
   ├─ force_delete                  false by default
   └─ tags                          var.tags < the repository's own tags
   ▼
aws_ecr_lifecycle_policy.this[<key>]   two rules, see below
aws_ecr_repository_policy.this[<key>]  only when a cross-account principal is named
   ▼
outputs: repository_urls, repository_arns, repository_arns_list, repository_names,
         repositories, registry_id
```

- **One repository per domain function per environment.** The deciding argument is the lifecycle
  policy. `imageCountMoreThan` counts images in a repository, so eight domains sharing one
  repository with `countNumber = 10` would expire a domain's current image as soon as the other
  seven pushed twice. Separate repositories make "keep the last 10 tagged images" mean the last 10
  builds of that domain. Repositories themselves cost nothing, ECR bills storage, so there is no
  reason to economise on them.
- **Keys are the contract.** The map key is the short domain name, and it survives into every
  output and into the resource address. CI reads `module.<name>.repository_urls` to know where to
  push, and nothing rebuilds a registry hostname from an account id and a region by hand.
- **Names are namespaced with a slash.** `name_prefix = "carmodpicker-production"` and a key of
  `parts` give `carmodpicker-production/parts`. ECR allows slashes in a repository name and the
  console groups on them, so one environment's domains sort together.
- **Module-wide inputs, per-repository overrides.** Every knob that varies is a module-wide input
  that any single repository can override with a value of its own, the same shape `dynamodb-tables`
  uses for `point_in_time_recovery` and `deletion_protection`.

## Usage

```hcl
module "registry" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ecr-repository"
  version = "~> 1.8"

  name_prefix = "carmodpicker-production"

  repositories = {
    parts       = {}
    users       = {}
    build-lists = {}
  }
}
```

`examples/ecr-repository-basic` at the repository root is the fuller version, with per-repository
overrides, the CI push policy and the Lambda that runs one of the images.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `repositories` | Map of short domain key to per-repository overrides, see below | required |
| `name_prefix` | Prefix joined to each key with a slash to form the repository name; empty uses the key verbatim | `""` |
| `image_tag_mutability` | `IMMUTABLE` or `MUTABLE`; a repository can override | `"IMMUTABLE"` |
| `scan_on_push` | Basic scan on push, the free scanner; a repository can override | `true` |
| `keep_last_tagged_images` | Tagged images kept by the second lifecycle rule; a repository can override | `10` |
| `expire_untagged_after_days` | Age at which an untagged image is expired; a repository can override | `1` |
| `tag_prefix_list` | Tag prefixes the "keep the last N" rule selects on; a repository can override | `["sha-"]` |
| `create_lifecycle_policy` | Create the lifecycle policy at all | `true` |
| `encryption_type` | `AES256`, `KMS` or `KMS_DSSE` | `"AES256"` |
| `encryption_kms_key` | KMS key ARN, only with a KMS `encryption_type` | `null` |
| `force_delete` | Let Terraform delete a repository that still holds images; a repository can override | `false` |
| `repository_policy_principals` | IAM principal ARNs allowed to pull cross-account; empty creates no policy | `[]` |
| `repository_policy_json` | A complete repository policy, replacing the generated one | `null` |
| `tags` | Tags on every repository, on top of `default_tags`; empty is passed as `null` | `{}` |

Each entry in `repositories`, every field optional and `null` taking the module-wide value:

| Field | Description | Default |
| --- | --- | --- |
| `image_tag_mutability` | Per-repository override | `null` |
| `scan_on_push` | Per-repository override | `null` |
| `keep_last_tagged_images` | Per-repository override | `null` |
| `expire_untagged_after_days` | Per-repository override | `null` |
| `tag_prefix_list` | Per-repository override | `null` |
| `lifecycle_policy` | A complete lifecycle policy JSON, replacing the two generated rules | `null` |
| `force_delete` | Per-repository override | `null` |
| `tags` | Extra tags for this repository | `{}` |

`{}` is the normal entry: it takes every module-wide default.

## Outputs

| Name | Description |
| --- | --- |
| `repository_urls` | Short key to repository URL; the map CI pushes to and `image_uri` is built from |
| `repository_arns` | Short key to repository ARN |
| `repository_arns_list` | Every ARN as a list sorted by key, for an IAM resource list |
| `repository_names` | Short key to full repository name, which is what an ECR API call takes |
| `repositories` | Short key to `{ name, arn, url, registry_id }` |
| `registry_id` | The registry the repositories live in, which is the account id; `null` when the map is empty |

## The lifecycle policy

Two rules, in this order. Rule order is the contract: ECR applies the lowest `rulePriority` first.

```json
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Expire untagged images after 1 day",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 1
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Keep the last 10 tagged images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["sha-"],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    }
  ]
}
```

The rule semantics the module relies on, from
[Lifecycle policy properties](https://docs.aws.amazon.com/AmazonECR/latest/userguide/lifecycle_policy_parameters.html):

- **`tagStatus` of `tagged` requires a `tagPrefixList` or a `tagPatternList`, and `untagged`
  requires neither.** That is why the two rules are shaped differently, and why `tag_prefix_list`
  cannot be empty.
- **`tagPrefixList` matches on prefix; `tagPatternList` matches a wildcard pattern.** AWS documents
  `tagPatternList` as the best practice of the two, and `tagPrefixList` as what you use when you
  are not specifying a pattern list. This module writes `tagPrefixList`, because the estate's tags
  are `sha-<commit>` and a prefix says exactly that with no wildcard to get wrong. A repository
  that needs pattern matching passes a complete document through its `lifecycle_policy` field.
  Both keys are accepted by the AWS provider, which passes the document through as an opaque
  string.
- **A rule whose `tagStatus` is `any` must have the highest `rulePriority` and be evaluated last.**
  Neither generated rule uses `any`, but a hand-written `lifecycle_policy` that adds one has to
  respect this.
- **`countNumber` must be a positive integer.** `0` is rejected, which is what the input
  validations enforce at plan time rather than at apply time.
- **`imageCountMoreThan` counts images in the repository**, which is the whole reason this module
  is one repository per domain rather than one per environment.

Untagged images are what accumulate silently: every time a tag is moved or an image is replaced,
the previous one becomes untagged and keeps billing. One day is enough of a window to notice a bad
push.

**A lifecycle rule must never be able to expire an image a live function still needs.** A running
function pins a digest, so an expired image does not break it mid-flight, but it does break scaling
out into a new execution environment. Ten tagged builds is comfortable headroom; below about five
is not.

Note that a tagged image matching no prefix in `tag_prefix_list` is never selected by rule 2 and so
is never expired. If a repository carries a second tag scheme, list both prefixes, or nothing will
ever clean the second one up.

## Lambda, and why there is no repository policy by default

**A same-account container-image Lambda needs no repository policy and no ECR permission on its
execution role.** From
[Create a Lambda function using a container image](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html),
under "Amazon ECR permissions":

> In IAM, same-account access requires only one side to grant permission, either the identity-based
> policy (on the role) or the resource-based policy on the Amazon ECR repository.

and:

> If the Amazon ECR repository does not include these permissions, Lambda attempts to add them
> automatically. Lambda can add permissions only if the principal calling Lambda has
> `ecr:getRepositoryPolicy` and `ecr:setRepositoryPolicy` permissions.

So on `CreateFunction`, Lambda writes the `LambdaECRImageRetrievalPolicy` statement onto the
repository itself, provided the caller creating the function holds `ecr:GetRepositoryPolicy` and
`ecr:SetRepositoryPolicy`. That is the one permission requirement this pattern does add, and it
lands on the **deploy role**, not on the function's execution role. Grant the CI or Terraform role
`ecr:GetRepositoryPolicy`, `ecr:SetRepositoryPolicy`, `ecr:BatchGetImage` and
`ecr:GetDownloadUrlForLayer` on the repositories, which the AWS docs spell out in the same section.

This is worth stating precisely, because a plausible-sounding version of the claim is wrong in a
way that costs an afternoon. Lambda does re-fetch the image on its own service identity, to
optimise and cache it and to bring a function back from `Inactive`, and a function whose image it
cannot re-fetch goes to `Failed`. What makes that safe same-account is not that the service
identity bypasses authorization, it is that Lambda has already put the statement on the repository
for you. If something strips that statement later, or a deploy role lacking
`ecr:SetRepositoryPolicy` created the function, the failure shows up minutes or weeks after a
deploy that looked fine. If you would rather not depend on Lambda writing it, name the account
explicitly in `repository_policy_principals`, which makes the statement Terraform's to own.

Cross-account is the case that genuinely needs both sides, and it is what
`repository_policy_principals` is for. Given one or more principal ARNs the module writes:

- `CrossAccountPull`, letting those principals run `ecr:BatchGetImage`,
  `ecr:GetDownloadUrlForLayer` and `ecr:DescribeImages`.
- `LambdaCrossAccountImageRetrieval`, letting `lambda.amazonaws.com` retrieve the image on behalf
  of a function in one of those accounts, conditioned with `ArnLike` on `aws:sourceARN`. The AWS
  docs call this one out specifically: without it a cross-account container-image function deploys
  and then fails later, when Lambda tries to re-fetch the image.

The consuming account still grants the same actions on its own function role, because cross-account
access requires both halves.

Two constraints worth having in one place:

- **The repository and the function must be in the same region.** Lambda cannot pull a container
  image cross-region. It can pull cross-account, but not cross-region.
- **No replication is configured, deliberately.** ECR replication bills storage in both regions.
  This estate is single-region, so a replication rule would be pure cost.

## Immutable tags

`IMMUTABLE` is the default and it is the property worth keeping: a tag that cannot move is what
makes a deploy reproducible and makes the digest recorded on the function meaningful.

The trade it forces is worth stating, because it surprises people. **Tag mutability is a
repository-level setting, not a per-tag one.** So an immutable repository cannot also carry a
moving `env-staging`-style pointer tag. That is not much of a loss: `aws lambda get-function
--query 'Code.ImageUri'` already answers "what is this environment running", which is the question
the moving tag existed to answer. A repository that genuinely needs a moving tag sets
`image_tag_mutability = "MUTABLE"` on its own entry, and should list both prefixes in its
`tag_prefix_list` so the lifecycle rule still sweeps it.

## Scanning

`scan_on_push = true` turns on **basic scanning**, which is free and scans operating system
packages against the CVE database at push time.

**Enhanced scanning is out of scope for this module, on purpose.** It is a different feature: it is
Amazon Inspector, it covers language packages as well as OS packages, and it continuously rescans
stored images as new CVEs are published. Two things follow. First, it is configured **once per
registry at the account level**, in the ECR private registry scanning configuration, not per
repository, so it is not a per-repository input this module could sensibly own. Second, it bills
per image scanned and per rescan, against every image in the registry, which is exactly the
cost-at-rest shape this estate is avoiding. Basic scanning plus a dependency audit in CI covers the
same ground for nothing. Revisit it if the estate ever handles third-party data.

## Encryption

`AES256` is the default: the ECR managed key, no per-request charge. `KMS` uses a KMS key and adds
a KMS request charge on every layer upload and pull, which buys nothing here that AES256 does not
already give. Set `encryption_type = "KMS"` with `encryption_kms_key` when a compliance rule asks
for a customer managed key, and leave the key `null` to use the account's `aws/ecr` managed key.

Encryption is fixed when a repository is created. **Changing either encryption input replaces every
repository**, which destroys the images in them, so this is a decision to get right at creation.

## Cost

Verified on the [ECR pricing page](https://aws.amazon.com/ecr/pricing/) on 2026-09-07:

| Dimension | Price |
| --- | --- |
| Private repository storage | **$0.10 per GB-month** |
| Data transfer, ECR to Lambda in the same region | **$0.00 per GB** |
| Repositories themselves | free, ECR bills storage only |
| Basic scanning | free |

The pricing page states that data transferred between ECR and other services in the same region,
naming AWS Lambda among them, is free of charge. Repository count does not enter the bill, which is
what makes one repository per domain the cheap option as well as the correct one.

**ECR bills unique layers, not the sum of image sizes.** A shared base image and a shared dependency
install are one set of layers every domain image references; only the thin application layer
differs. A ten-domain environment retaining ten builds each lands around 1 GB, roughly **$0.10 per
environment per month**, well under a dollar for a four-environment estate.

That layer sharing is load-bearing. It holds only while every domain image is built `FROM` the same
base with the same dependency install, so the layers are bit-identical. Give each domain its own
trimmed dependency set and the dependency layer stops being shared and the number roughly triples.
Still small, but it moves the wrong way, and building every domain from one shared dependency layer
is simpler besides.

The dominant term is retained history, which is what `keep_last_tagged_images` controls. Halving it
roughly halves storage and saves a few cents, which is not worth trading rollback headroom for.

## Notes

- **`force_delete` is `false` by default.** A destroy fails while a repository still holds images,
  which is the right friction for anything a function pulls from. Staging environments that are
  torn down and rebuilt set it `true`.
- **`create_lifecycle_policy = false`** leaves repositories with no policy, so nothing is ever
  expired and storage grows with every push. It exists so a repository can be adopted before its
  policy is, not as a setting to leave off.
- **Setting both `repository_policy_json` and `repository_policy_principals` is refused at plan
  time**, because only one of them could win.
