# terraform-aws-codeartifact

One CodeArtifact domain and the repositories inside it, with the domain and repository policies that
let CI jobs in other AWS accounts read from it and named principals publish into it. Repository
upstream chains are ordered for you, and the endpoint URLs and consumer IAM statements come back as
outputs.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/codeartifact`.

## Usage

```hcl
module "codeartifact" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/codeartifact"
  version = "~> 1.8"

  domain = "example"

  repositories = {
    pypi-store = { external_connections = ["public:pypi"] }
    npm-store  = { external_connections = ["public:npmjs"] }
    python     = { upstreams = ["pypi-store"] }
    node       = { upstreams = ["npm-store"] }
    shared     = { upstreams = ["python", "node"] }
  }

  reader_account_ids       = ["123456789012"]
  publisher_principal_arns = ["arn:aws:iam::123456789012:role/example-package-publisher"]
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `domain` | Domain name, 2 to 50 lowercase characters | required |
| `repositories` | Repositories keyed by name; see the shape below | required |
| `encryption_key` | Symmetric KMS key ARN or id for every asset; null uses `aws/codeartifact` | `null` |
| `tags` | Tags on the domain and every repository | `{}` |
| `reader_account_ids` | Account ids granted read on the domain and every repository | `[]` |
| `reader_principal_arns` | Principal ARNs granted read, instead of or alongside whole accounts | `[]` |
| `publisher_principal_arns` | Principal ARNs allowed to publish package versions | `[]` |
| `publisher_repository_keys` | Repositories publishers may write to; null means every non-store one | `null` |
| `reader_domain_actions` | Domain actions in the reader statement | see below |
| `reader_repository_actions` | Repository actions in the reader statement | see below |
| `publisher_repository_actions` | Repository actions in the publish statements | see below |
| `domain_policy_sid` | Sid on the domain policy's reader statement; null renders none | `"CrossAccountRead"` |
| `domain_policy_document` | A complete domain policy JSON replacing the generated one | `null` |
| `endpoint_formats` | Package formats to resolve an endpoint for, per repository | `["pypi", "npm"]` |

Each entry in `repositories`:

```hcl
{
  description          = optional(string)
  external_connections = optional(list(string), [])
  upstreams            = optional(list(string), [])
  tags                 = optional(map(string), {})
}
```

Action list defaults:

| Variable | Default |
| --- | --- |
| `reader_domain_actions` | `DescribeDomain`, `GetAuthorizationToken`, `GetDomainPermissionsPolicy`, `ListRepositoriesInDomain` |
| `reader_repository_actions` | `DescribePackageVersion`, `DescribeRepository`, `GetPackageVersionAsset`, `GetPackageVersionReadme`, `GetRepositoryEndpoint`, `ListPackageVersionAssets`, `ListPackageVersionDependencies`, `ListPackageVersions`, `ListPackages`, `ReadFromRepository` |
| `publisher_repository_actions` | `PublishPackageVersion`, `PutPackageMetadata`, `ReadFromRepository` |

## Outputs

| Name | Description |
| --- | --- |
| `domain` | Domain name, for `--domain` |
| `domain_owner` | Owning account id, which every other account must pass as `--domain-owner` |
| `domain_arn` | Domain ARN, the resource for `GetAuthorizationToken` |
| `repository_arns` | Repository key to ARN |
| `repository_names` | Repository key to name |
| `endpoints` | `"<repository>:<format>"` to endpoint URL, for example `"shared:pypi"` |
| `consumer_resource_arns` | `{ domain, repositories }`, the ARN set a consumer's own policy names |
| `consumer_policy_statements` | Three ready-made IAM statements for a consumer's own role |

## Gotchas

- Package-level actions such as `DescribePackageVersion`, `PublishPackageVersion` and
  `PutPackageMetadata` need the package ARN, not the repository ARN. The module renders
  `PublishPackageVersion` and `PutPackageMetadata` on `package/<domain>/<repository>/*` in their own
  statement; mixing them with repository-scoped actions gets the policy rejected at apply time with
  `ValidationException`, which no plan catches.
- Moving a repository between tiers replaces it and loses its packages. Giving a repository its first
  upstream moves it from `aws_codeartifact_repository.tier0` to `.tier1`; write a `moved` block in
  the calling stack before applying.
- Upstream chains are capped at three tiers by validation, because a string-named upstream gives
  Terraform no dependency edge and the ordering is hand-chained with `depends_on`.
- `encryption_key` is immutable on the domain. A different key means a new domain and a repopulation
  of every repository in it.
- A repository may hold at most one external connection, and a repository with an external connection
  may not also have upstreams. Both are validated at plan time.
- Publishers never reach a store repository: naming one in `publisher_repository_keys` fails a
  precondition, because a first-party package there would shadow the public package it proxies.
- Both sides of a cross-account grant must allow. The consumer's own role also needs
  `sts:GetServiceBearerToken` on `Resource "*"`, which is the piece most often forgotten and which
  `consumer_policy_statements` includes.
- `ReadFromRepository` is all or nothing per repository; a package ARN cannot narrow it to a subset
  of packages.
- Upstream order is significant and the whole list is replaced on update, so reordering `upstreams`
  is a real change. AWS caps a repository at 10 direct upstreams.
- `domain_policy_document` replaces the generated domain policy only. `reader_account_ids` and
  `reader_principal_arns` still drive the repository policies.
- Storage is billed once per domain, so an estate wants exactly one domain. A second domain doubles
  the storage bill and the number of cross-account policies to keep in step.
