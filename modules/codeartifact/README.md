# terraform-aws-codeartifact

One CodeArtifact domain and the repositories inside it, with the cross-account grants that let CI
jobs in other AWS accounts read from it. A store repository holds the external connection to a
public registry, an internal repository holds first-party packages and upstreams to its store, and
an optional fan-in repository upstreams to both so every CI job points at a single endpoint per
package manager.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/codeartifact`.

## How it works

```
var.repositories = { <name> = { description?, external_connections?, upstreams?, tags? } }
   │
   ▼
aws_codeartifact_domain.this                       one per estate, storage billed once
   ├─ aws_codeartifact_domain_permissions_policy   GetAuthorizationToken for reader accounts
   │
   ├─ aws_codeartifact_repository.tier0            no upstreams: the external-connection stores
   ├─ aws_codeartifact_repository.tier1            upstreams into tier0
   ├─ aws_codeartifact_repository.tier2            upstreams into tier0 or tier1: the fan-in
   │
   └─ aws_codeartifact_repository_permissions_policy[<name>]
          Read     for reader accounts and principals, on every repository
          Publish  for publisher principals, on internal repositories only
   ▼
data.aws_codeartifact_repository_endpoint["<repository>:<format>"]
   ▼
outputs: domain, domain_owner, domain_arn, repository_arns, repository_names,
         endpoints, consumer_resource_arns, consumer_policy_statements
```

- **Exactly one domain.** CodeArtifact deduplicates storage per domain: "An asset only needs to be
  stored once in a domain, even if it's available in 1 or 1,000 repositories. That means you only
  pay for storage once" ([Domain overview][domain-overview]). A second domain is a second copy of
  every shared asset and a second set of cross-account grants to keep in step, so the module takes
  a single `domain` string and the estate calls it once.
- **Upstream ordering is explicit, because Terraform cannot see it.** An `upstream` block names its
  target by a plain string, not by a reference to another instance of the same resource, so
  Terraform has no dependency edge to order on, and a `for_each` resource cannot depend on itself
  anyway. Creating a repository whose upstream does not exist yet fails outright rather than
  converging on a retry. The module splits the map into three `aws_codeartifact_repository`
  resources by upstream depth and chains them with `depends_on`. A validation caps chains at three
  tiers, which covers store to internal to fan-in and rejects anything deeper as a mistake.
- **A store repository has an external connection and nothing else.** Two separate rules produce
  this. "Each CodeArtifact repository can only have one external connection" is stated flatly and
  repeatedly ([External connections][external-connection]). Combining an external connection with
  upstreams is a weaker rule: the `AssociateExternalConnection` reference notes that "a repository
  can have one or more upstream repositories, or an external connection"
  ([AssociateExternalConnection][associate-external-connection]), but no error is documented for
  violating it, and `CreateRepository` does not repeat the note. The module validates both anyway,
  because the store-plus-internal split is what the user guide calls "the intended way to use
  external connections" regardless: one repository per domain holds the connection to a given
  public registry and everything else upstreams to it, so a fetched asset is stored once rather
  than re-fetched per repository.
- **Publishers never reach a store repository.** `publisher_repository_keys` defaults to every
  repository without an external connection, and naming a store repository explicitly fails a
  precondition. A first-party package published into the repository that proxies PyPI would shadow
  the public package of the same name for everything downstream of it.
- **Both sides of a cross-account grant have to allow.** The domain and repository policies here
  are only half of it. The consumer's own role still needs an identity-based policy, which is what
  the `consumer_policy_statements` output hands back ready to attach.

### The action set, and where it comes from

`codeartifact:GetAuthorizationToken` is a **domain-level** action, so a repository policy alone
cannot grant it however many repository permissions it carries. That is what makes the domain
policy the single place to revoke an account's access to the whole registry
([Domain policies][domain-policies]).

On the repository, the user guide gives the set a principal downloading packages needs, on the
grounds that "a user who downloads packages from a repository needs to interact with it in other
ways too" ([Repository policies][repo-policies]): `DescribePackageVersion`, `DescribeRepository`,
`GetPackageVersionReadme`, `GetRepositoryEndpoint`, `ListPackages`, `ListPackageVersions`,
`ListPackageVersionAssets`, `ListPackageVersionDependencies` and `ReadFromRepository`. The module
defaults add `GetPackageVersionAsset`, which is the action that fetches the wheel or the tarball
itself once the manager has listed it.

Two things the same page is worth quoting on:

- `ReadFromRepository` is all or nothing per repository. "You cannot put a package's Amazon Resource
  Name (ARN) as a resource with `codeartifact:ReadFromRepository` as the action to allow read access
  to a subset of packages in a repository. A given principal can either read all the packages in a
  repository or none of them."
- For publishing, `PublishPackageVersion` is the base action, and the page's Important note adds
  `PutPackageMetadata` for Maven and `ReadFromRepository` for NuGet. The module's publisher default
  carries all three: `ReadFromRepository` is also what lets a publisher check whether a version
  already exists before it tries to create it.

The piece most often forgotten is not a CodeArtifact action at all. `sts:GetServiceBearerToken`
lives in the consumer's own identity policy, and without it `get-authorization-token` fails no
matter what the resource policies say. `consumer_policy_statements` includes it, pinned with a
`sts:AWSServiceName` condition so the grant cannot mint a bearer token for another service.

[domain-overview]: https://docs.aws.amazon.com/codeartifact/latest/ug/domain-overview.html
[domain-policies]: https://docs.aws.amazon.com/codeartifact/latest/ug/domain-policies.html
[repo-policies]: https://docs.aws.amazon.com/codeartifact/latest/ug/repo-policies.html
[external-connection]: https://docs.aws.amazon.com/codeartifact/latest/ug/external-connection.html
[associate-external-connection]: https://docs.aws.amazon.com/codeartifact/latest/APIReference/API_AssociateExternalConnection.html

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `domain` | Domain name, 2 to 50 lowercase characters, no trailing hyphen | required |
| `repositories` | Map of repository name to definition, see below | required |
| `encryption_key` | Symmetric KMS key ARN or id for every asset in the domain; immutable after create | `null` |
| `reader_account_ids` | AWS account ids granted read on the domain and every repository | `[]` |
| `reader_principal_arns` | Principal ARNs granted read, instead of or alongside whole accounts | `[]` |
| `publisher_principal_arns` | Principal ARNs allowed to publish package versions | `[]` |
| `publisher_repository_keys` | Repositories publishers may write to; `null` means every non-store one | `null` |
| `reader_domain_actions` | Domain actions in the reader statement | see below |
| `reader_repository_actions` | Repository actions in the reader statement | see below |
| `publisher_repository_actions` | Repository actions in the publish statement | see below |
| `domain_policy_sid` | Sid on the domain policy's reader statement; `null` renders none | `"CrossAccountRead"` |
| `domain_policy_document` | A complete domain policy JSON replacing the generated one | `null` |
| `endpoint_formats` | Formats to resolve an endpoint for, per repository | `["pypi", "npm"]` |
| `tags` | Tags on the domain and every repository, on top of `default_tags` | `{}` |

Each entry in `repositories`:

| Field | Description | Default |
| --- | --- | --- |
| `description` | Shown in the console and the API | `null` |
| `external_connections` | Public registries to proxy, for example `["public:pypi"]`; at most one, and never alongside upstreams | `[]` |
| `upstreams` | Keys of other repositories in the same map, searched in list order; at most 10 | `[]` |
| `tags` | Extra tags for this repository | `{}` |

Action defaults:

| Variable | Default |
| --- | --- |
| `reader_domain_actions` | `DescribeDomain`, `GetAuthorizationToken`, `GetDomainPermissionsPolicy`, `ListRepositoriesInDomain` |
| `reader_repository_actions` | `DescribePackageVersion`, `DescribeRepository`, `GetPackageVersionAsset`, `GetPackageVersionReadme`, `GetRepositoryEndpoint`, `ListPackageVersionAssets`, `ListPackageVersionDependencies`, `ListPackageVersions`, `ListPackages`, `ReadFromRepository` |
| `publisher_repository_actions` | `PublishPackageVersion`, `PutPackageMetadata`, `ReadFromRepository` |

`CreateRepository` is deliberately absent from the domain default. Consumers read; they do not
create repositories in someone else's domain.

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
| `consumer_policy_statements` | Three ready-made IAM statements for a consumer's role |

Wiring a consumer's GitHub Actions role, in the consumer account's own stack:

```hcl
module "deploy_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 1.8"

  role_name = "carmodpicker-production-github-actions-deploy"
  subjects  = ["repo:WebbPulse/CarModPicker:*"]

  policy_statements = concat(
    local.existing_deploy_statements,
    [for s in data.terraform_remote_state.platform.outputs.codeartifact_consumer_policy_statements : {
      sid       = s.Sid
      actions   = s.Action
      resources = s.Resource
      condition = try(s.Condition, null)
    }],
  )
}
```

## Consumer setup

A GitHub Actions job in an application account. There are no personal tokens anywhere in this: the
job gets an OIDC token from GitHub, exchanges it for its own account's role, and that role fetches
a CodeArtifact token that lives only in the job.

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v6
    with:
      role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
      aws-region: us-west-2

  - name: CodeArtifact token
    run: |
      TOKEN=$(aws codeartifact get-authorization-token \
        --domain webbpulse --domain-owner "$CODEARTIFACT_OWNER" \
        --query authorizationToken --output text \
        --duration-seconds 0)
      echo "::add-mask::$TOKEN"
      printf '%s' "$TOKEN" > "$RUNNER_TEMP/ca_token"
```

`--duration-seconds 0` ties the token to the remaining time in the assumed-role session, so it
cannot outlive the job's own credentials. Without it a token defaults to 12 hours and its lifetime
is independent of the role's maximum session duration, which means a 15-minute role session can
otherwise mint a 12-hour token. `::add-mask::` keeps it out of the log if a later step echoes it.

Nothing is written into the repository working tree. `$RUNNER_TEMP` is outside the checkout and is
discarded with the runner, so the token cannot be committed by accident or picked up by a later
step that archives the workspace.

For pip, `aws codeartifact login` does the config write for you:

```bash
aws codeartifact login --tool pip --domain webbpulse \
  --domain-owner "$CODEARTIFACT_OWNER" --repository shared
```

That writes `index-url` into the user's `pip.conf` with the token embedded. In CI that file is in
the runner's home directory and dies with the runner. If you would rather be explicit, set the
environment variable instead and write no file at all:

```bash
PIP_INDEX_URL="https://aws:$(cat "$RUNNER_TEMP/ca_token")@${CODEARTIFACT_HOST}/pypi/shared/simple/"
export PIP_INDEX_URL
pip install -r requirements.txt
```

For npm, `login --tool npm` writes the registry and the auth token into `~/.npmrc`. Write it there
rather than into the repository's own `.npmrc`, which is checked in:

```bash
aws codeartifact login --tool npm --domain webbpulse \
  --domain-owner "$CODEARTIFACT_OWNER" --repository shared
```

The equivalent by hand, again into the home directory:

```bash
{
  echo "registry=${NPM_REGISTRY}"
  echo "${NPM_REGISTRY#https:}:_authToken=$(cat "$RUNNER_TEMP/ca_token")"
} >> "$HOME/.npmrc"
```

`NPM_REGISTRY` is the `endpoints["shared:npm"]` output; `CODEARTIFACT_HOST` is the host part of
`endpoints["shared:pypi"]`. Both come from the platform stack rather than being assembled by hand.

### Docker builds

A `docker build` that installs from the domain needs the token inside the build, and the two
obvious ways of getting it there both leak it:

| Approach | Verdict |
| --- | --- |
| `ARG CODEARTIFACT_TOKEN` | No. Build args are recorded in image history and `docker history` prints them, so the token ships with the image |
| `ENV PIP_INDEX_URL=https://aws:$TOKEN@...` | No. Same leak, and it also persists into the running container's environment |
| BuildKit secret mount | Yes. Mounted into one `RUN` and never written to a layer |

```dockerfile
# syntax=docker/dockerfile:1.7
FROM public.ecr.aws/docker/library/python:3.13-slim AS build

COPY requirements.txt .
RUN --mount=type=secret,id=codeartifact_token \
    PIP_INDEX_URL="https://aws:$(cat /run/secrets/codeartifact_token)@${CODEARTIFACT_HOST}/pypi/shared/simple/" \
    pip install --no-cache-dir --target /deps -r requirements.txt

FROM public.ecr.aws/docker/library/python:3.13-slim
COPY --from=build /deps /deps
```

```yaml
  - run: |
      docker build \
        --secret id=codeartifact_token,src=$RUNNER_TEMP/ca_token \
        --build-arg CODEARTIFACT_HOST="$CODEARTIFACT_HOST" \
        -t "$IMAGE" .
```

The host is a build arg because it is not a secret. The token is a mount because it is. The build
is multi-stage so that even the environment of the `RUN` that used the token does not reach the
final image: only `/deps` is copied forward.

## Cost

Verified against https://aws.amazon.com/codeartifact/pricing/ and the metered unit map behind it on
2026-09-07, us-west-2:

| Dimension | Price |
| --- | --- |
| Storage | $0.05 per GB-month |
| Requests | $0.05 per 10,000 requests, that is $0.000005 each |
| Data transfer in from the internet | $0.00 |
| Data transfer to another AWS service in the same Region | $0.00 |
| Data transfer out to the internet | Standard AWS tiering, first 1 GB per month free |

There is also a monthly free tier for both storage and requests, which the pricing page states
without giving the allowance in a machine-readable form. Treat it as a cushion rather than as the
plan.

Two things follow. First, requests are not worth optimising: the pricing page notes that "every
asset downloaded by CodeArtifact from public artifact repositories (npm registry, maven central,
PyPI, NuGet.org, and so on) counts towards the request count", so a cold `docker build` pulling
forty wheels is forty-ish requests, or $0.0002. A thousand such builds a month is under a dollar.
Second, and this is why the module takes one domain rather than a list: **storage is billed once
per domain.** Splitting the same packages across two domains doubles the storage bill and doubles
the number of cross-account policies to keep in step, for nothing. Tens of megabytes of first-party
packages plus a few hundred megabytes of cached public wheels is cents per month in one domain and
twice that in two.

The reason to run the upstream at all is not cost. It is that an asset pulled into a store
repository is retained, so a package yanked from PyPI does not break a build, and the set of
external packages the estate actually depends on becomes enumerable in one place.

## Known limits

- **The domain's KMS key cannot be changed.** `encryption_key` is immutable on
  `aws_codeartifact_domain`; a different key means a new domain and a repopulation of every
  repository in it.
- **Upstream chains are capped at three tiers.** The ordering is expressed as explicit
  `depends_on`-chained resources rather than a loop, because Terraform cannot derive the dependency
  from a string-named upstream. Store to internal to fan-in fits; a fourth level does not, and the
  validation says so at plan time.
- **Moving a repository between tiers replaces it.** Adding a first upstream to a repository that
  had none moves it from `aws_codeartifact_repository.tier0` to `.tier1`, which Terraform sees as a
  destroy and a create. Packages published to it would be lost. A `moved` block in the calling
  stack fixes it: the block goes in the root module, names both addresses through the module, and
  turns the replace back into a no-op.

  ```hcl
  # "python" gained its first upstream, so it moves from tier0 to tier1.
  moved {
    from = module.codeartifact.aws_codeartifact_repository.tier0["python"]
    to   = module.codeartifact.aws_codeartifact_repository.tier1["python"]
  }
  ```

  The tier a repository lands in is a function of its upstream depth: no upstreams is `tier0`,
  upstreams only into tier0 is `tier1`, anything deeper is `tier2`. Adding `shared` above an
  existing `python` therefore moves nothing that already existed, but giving `python` its first
  upstream moves `python`. Read the plan before applying: it must show the move and
  `0 to add, 0 to change, 0 to destroy` for that repository.
- **`ReadFromRepository` cannot be narrowed to a subset of packages.** Per-package read control is
  not something a repository policy can express; a repository is the unit of read access.
- **One external connection per repository.** Enforced by CodeArtifact, and validated here so the
  plan fails with the reason rather than with a block count. The module additionally refuses to
  combine an external connection with upstreams on one repository; that second rule is the API
  reference's note rather than a documented error, so it is the module being deliberately stricter
  than the service.
- **Upstream order is significant, and the whole list is replaced on update.** CodeArtifact
  searches direct upstreams in list order, so reordering the `upstreams` list is a real change, not
  a cosmetic one. AWS caps a repository at 10 direct upstreams and stops after searching 25
  repositories in one resolution.
- **The module does not create the consumer's IAM role.** It hands back
  `consumer_policy_statements` for the consumer account's own stack to attach, because that role
  lives in a different account and usually a different workspace.

## Adoption

There is nothing to adopt. Unlike the other modules in this repository, this one does not take over
existing resources: the CodeArtifact domain does not exist yet in any account, so the first apply
is a create, not a move. There are no `moved` blocks to write.

The module ships from 1.8.0, so consumers pin `version = "~> 1.8"`.

### WebbPulse Platform account

The domain and its repositories live in the platform account, called once from that account's
stack. The example under [`examples/codeartifact-basic`](../../examples/codeartifact-basic/) is the
shape the estate runs, reader account ids included. Apply it there first and read the plan: five
repositories, one domain, one domain policy and five repository policies, and nothing else.

### The four application accounts

Each application account attaches the other half of the grant to its own deploy role. Nothing in
this module runs in those accounts; they consume two outputs.

```hcl
data "terraform_remote_state" "platform" {
  backend = "remote"
  config = {
    organization = "WebbPulse"
    workspaces = { name = "WebbPulse-Platform-production" }
  }
}

module "deploy_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 1.8"

  role_name = "carmodpicker-production-github-actions-deploy"
  subjects  = ["repo:WebbPulse/CarModPicker:*"]

  policy_statements = concat(
    local.existing_deploy_statements,
    [for s in data.terraform_remote_state.platform.outputs.codeartifact_consumer_policy_statements : {
      sid       = s.Sid
      actions   = s.Action
      resources = s.Resource
      condition = try(s.Condition, null)
    }],
  )
}
```

Order matters across the two applies. The domain and repository policies name the reader accounts,
and the consumer roles name the domain and repository ARNs, so the platform account applies first
and the application accounts pick the ARNs up on their next plan. A consumer that applies before
the platform account reads an empty remote state and drops the CodeArtifact statements from its
role, which fails closed rather than open: builds keep working against the public registries until
the role is reapplied.
