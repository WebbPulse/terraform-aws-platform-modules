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
| [`modules/api-alarms`](modules/api-alarms/) | SNS topic with email subscriptions plus CloudWatch alarms for Lambda errors and throttles, HTTP API 5xx and integration latency, and DynamoDB throttles either as one alarm per environment or one per table. |
| [`modules/app-secrets`](modules/app-secrets/) | A map of Secrets Manager secrets in five shapes (generated, given, JSON, placeholder, empty) with a ready-made read policy for the app role. |

Each module README carries an "Adoption" section with the `moved` blocks and variable values that
take over an application's existing resources with zero destroy or replace. Planned next: a root
composite that calls all of them so a new project is one module block.

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
