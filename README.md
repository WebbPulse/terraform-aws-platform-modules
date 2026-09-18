# terraform-aws-platform-modules

The shared Terraform modules behind every WebbPulse application estate. One repository, one
semver tag, many submodules. Published to the WebbPulse HCP Terraform private registry as
`platform-modules/aws` by [WebbPulse-Platform](https://github.com/WebbPulse/WebbPulse-Platform),
which also owns this repository.

## Consuming a module

```hcl
module "gate" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/staging-access-gate"
  version = "~> 1.0"
  # ...
}
```

The `version` constraint applies to the whole repository: a tag covers every submodule. Consumers
pin `~> MAJOR.0` and pick up minor and patch releases on their next plan. That coupling is
deliberate. The application repositories are meant to be near-identical, so a fix to a shared
pattern should reach all of them, and the place to notice a behavior change is the plan.

A two-segment constraint such as `~> 1.1` or `~> 1.3` floats across all of 1.x, so it picks up
every later minor release, not just patches on that minor. That is what the module READMEs
intend. Write `~> 1.3.0` instead to hold a minor and take patch releases only.

[`CHANGELOG.md`](CHANGELOG.md) records what each release changed and, for a minor, whether an
existing consumer's plan stays empty.

## Modules

| Module | What it is |
| --- | --- |
| [`modules/staging-access-gate`](modules/staging-access-gate/) | Cognito sign-in plus CloudFront signed cookies and an HTTP API origin-verify authorizer, gating a staging site to an allow-list of emails. |
| [`modules/spa-frontend`](modules/spa-frontend/) | Private S3 bucket behind a CloudFront distribution with OAC, optional alias records, and an optional `access_gate` object that wires in the staging access gate's origins and behaviors. |
| [`modules/http-api`](modules/http-api/) | API Gateway HTTP API in front of a Lambda: routes, access logging, default stage, optional custom domain, and the gate's authorizer plus execute-api shutoff when asked. |
| [`modules/github-actions-role`](modules/github-actions-role/) | GitHub Actions OIDC provider and deploy role with a statement-list inline policy rendered byte-identically to the hand-written originals. |
| [`modules/staging-dns`](modules/staging-dns/) | A `staging.<domain>` hosted zone plus its NS delegation in the parent zone through an `aws.parent` provider alias. |
| [`modules/app-baseline`](modules/app-baseline/) | Per-application account baseline: a resource group, a Cost Explorer anomaly monitor and subscription, and a map of monthly budgets with email notifications. |
| [`modules/lambda-artifacts-bucket`](modules/lambda-artifacts-bucket/) | Versioned private S3 bucket for CI-built Lambda zips with noncurrent-version expiry, optional SSE, and an optional placeholder object. |
| [`modules/lambda-function`](modules/lambda-function/) | An API Lambda's role, log group and function with tracing, logging config and code-drift ignore rules; code arrives as a local zip or an S3 object, IAM attachments stay in the app. |
| [`modules/acm-certificate`](modules/acm-certificate/) | DNS validated ACM certificate whose validation records are written through a separate `aws.records` provider, so cross-account zones work. |
| [`modules/dynamodb-tables`](modules/dynamodb-tables/) | An application's DynamoDB tables as one map: keys, GSIs, TTL, PITR, deletion protection, optional streams and encryption. |
| [`modules/api-alarms`](modules/api-alarms/) | SNS topic with email subscriptions plus CloudWatch alarms for Lambda errors and throttles, either per function or summed across a function per domain, HTTP API 5xx and integration latency, and DynamoDB throttles either as one alarm per environment or one per table. Application errors from the logs are split from telemetry export failures so a dropped trace does not page as a failed request. |
| [`modules/app-secrets`](modules/app-secrets/) | A map of Secrets Manager secrets in five shapes (generated, given, JSON, placeholder, empty), written write-only so no value enters state, with a ready-made read policy for the app role. |
| [`modules/codeartifact`](modules/codeartifact/) | One CodeArtifact domain and its repositories, with the domain and repository policies that let CI in the application accounts read and two publisher roles write, plus ready-made IAM statements for the consumer side. |
| [`modules/ecr-repository`](modules/ecr-repository/) | An application's container registry as one map: one ECR repository per domain, immutable commit-SHA tags, scan on push, and a lifecycle policy that keeps storage flat. |
| [`modules/identity`](modules/identity/) | A product's identity layer for the shared identity standard: KMS RSA signing keys with an ordered rotation list, the ten identity DynamoDB tables with the key schemas the `webbpulse.identity` package requires, the signing and table IAM grants, an optional API Gateway JWT authorizer, and a ready to merge `IDENTITY_*` environment map. |
| [`modules/vpc-public`](modules/vpc-public/) | A VPC with public subnets only: internet gateway, one public route table, a locked down default security group and an egress-only task security group, with no NAT gateway and optional free S3 and DynamoDB gateway endpoints, so a task launched on demand reaches ECR and the AWS APIs over its own public IP. |
| [`modules/s3-bucket`](modules/s3-bucket/) | A general purpose private bucket: public access block, bucket owner enforced ownership, versioning, SSE-S3 or a KMS key it takes or creates, a TLS-only policy, optional lifecycle rules, EventBridge notifications and CORS, plus read-only and read-write policy documents scoped to the bucket and its key. |

Each module README carries its purpose, a minimal example, the full inputs and outputs tables, and
a "Gotchas" section. Anything longer lived, such as the `moved` blocks that adopted an existing
application's resources, is in the git history and in `CHANGELOG.md`.

## Layout

```
modules/<name>/         one module per directory: *.tf, README.md, and any runtime code it ships
examples/<name>-<case>/ runnable consumer examples, shown by the registry
versions.tf             the root module; empty on purpose until the composite exists
```

Each module directory is self-contained: its own `versions.tf`, its own README with inputs and
outputs, its own tests. Nothing under `modules/` references a sibling by relative path; a module
that needs another one consumes it through the registry like everyone else.

## Releasing

1. Merge to `main` through a pull request. The ruleset on `main` is managed by WebbPulse-Platform.
2. Tag the merge commit with the next semver, `v1.2.3`, and push the tag. The registry ingests it
   within a minute.
3. Semver rules apply across the repository. Removing or renaming a module input or output in any
   submodule is a major bump for the whole repo.

## Adding a module

Create `modules/<name>/` with `versions.tf`, `variables.tf`, `outputs.tf`, a README, and an
example under `examples/`. Add a row to the table above. Tag. There is nothing to register: the
registry lists every directory under `modules/` of the tagged commit.
