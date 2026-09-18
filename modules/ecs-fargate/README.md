# terraform-aws-ecs-fargate

Creates an ECS cluster and a map of Fargate task definitions for tasks launched on demand, with a
shared task execution role, a task role per task, a log group per task, and a ready-made policy for
whoever calls `RunTask`. No services, no load balancers, no scheduling: something else decides when
a task runs.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/ecs-fargate`.

## Usage

```hcl
module "tasks" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ecs-fargate"
  version = "~> 2.23"

  cluster_name = "example-staging"

  tasks = {
    plan = {
      image  = "123456789012.dkr.ecr.us-west-2.amazonaws.com/example-runner@sha256:..."
      cpu    = "1024"
      memory = "2048"

      environment = { TF_IN_AUTOMATION = "true" }

      secrets = {
        RUNNER_TOKEN = "arn:aws:secretsmanager:us-west-2:123456789012:secret:example/app-AbCdEf:runner_token::"
      }

      task_policy_statements = [
        {
          sid       = "ReadWriteState"
          actions   = ["s3:GetObject", "s3:PutObject"]
          resources = ["arn:aws:s3:::example-staging-terraform-state/*"]
        },
      ]

      log_retention_days = 14
    }
  }
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `cluster_name` | Cluster name as-is, not a prefix; changing it replaces the cluster | required |
| `tasks` | The task definitions to create, one entry per task; see the shape below | required |
| `container_insights` | `disabled`, `enabled` or `enhanced` | `"disabled"` |
| `cluster_tags` | Extra tags on the cluster only | `{}` |
| `execution_role_name` | Shared task execution role name, null for `<cluster_name>-task-execution` | `null` |
| `task_role_name_prefix` | Prefix for each task role, null for the cluster name | `null` |
| `role_path` | IAM path of the execution role and every task role | `"/"` |
| `permissions_boundary_arn` | Permissions boundary policy ARN on every role | `null` |
| `attach_execution_role_managed_policy` | Attach `AmazonECSTaskExecutionRolePolicy` to the execution role | `true` |
| `execution_role_policy_statements` | Extra statements for the execution role, on top of the derived secret grants | `[]` |
| `log_group_name_prefix` | Prefix for each task's log group, null for `/aws/ecs/<cluster_name>` | `null` |
| `role_tags` | Extra tags on every role | `{}` |
| `log_group_tags` | Extra tags on every task log group | `{}` |
| `tags` | Extra tags on every task definition | `{}` |

A `tasks` entry requires `image`, `cpu` and `memory`, and takes `command`, `family`,
`container_name`, `environment`, `secrets`, `architecture` (`ARM64` by default),
`operating_system_family`, `essential`, `readonly_root_filesystem`, `user`, `working_directory`,
`stop_timeout`, `ephemeral_storage_size`, `log_group_name`, `log_retention_days`,
`log_group_kms_key_id`, `task_policy_statements` and `tags`.

`secrets` maps an environment variable name to a Secrets Manager secret ARN or an SSM parameter
ARN; the execution role's read grant is derived from what you put there.

## Outputs

| Name | Description |
| --- | --- |
| `cluster_arn` | Cluster ARN, the value an `ecs:cluster` condition names |
| `cluster_name` | Cluster name |
| `task_definition_arns` | Revision-qualified ARN of each task definition |
| `task_definition_family_arns` | Family ARN of each task definition, without the revision |
| `task_definition_families` | Family name of each task definition |
| `task_definition_revisions` | Revision number of each task definition |
| `container_names` | Container name inside each task definition, for a `containerOverrides` block |
| `log_group_names` | Name of each task's log group |
| `log_group_arns` | ARN of each task's log group |
| `execution_role_arn` | Task execution role ARN |
| `execution_role_name` | Task execution role name |
| `execution_role_id` | Task execution role id, for an `aws_iam_role_policy` |
| `task_role_arns` | ARN of each task's own task role |
| `task_role_names` | Name of each task's own task role |
| `task_role_ids` | Id of each task's own task role |
| `run_task_policy_json` | Policy for a caller: `ecs:RunTask` on these families, plus `iam:PassRole` on the two roles |
| `secret_arns` | Every distinct secret and parameter ARN named across the task map |

## Gotchas

- The execution role and the task role are different roles and the split matters. The execution
  role is the Fargate agent, before the container starts: it pulls the image, reads the secrets and
  creates the log stream. The task role is the container's own code. Collapsing them hands the
  application everything the agent can do, including reading every secret any task in the map
  references. Container permissions go in a task's `task_policy_statements`, never in
  `execution_role_policy_statements`.
- `iam:PassRole` is what makes `RunTask` work. The caller hands ECS both roles, which IAM treats as
  passing them, so `ecs:RunTask` on its own is denied with a message about the roles rather than
  about the action. `run_task_policy_json` carries it, pinned to `ecs-tasks.amazonaws.com` with
  `iam:PassedToService`.
- `architecture` defaults to `ARM64` because Graviton is cheaper per vCPU-hour, and the image has to
  match. An amd64-only image on an arm64 task fails at container start with an exec format error,
  which is a runtime failure rather than an apply failure, so it surfaces on the first run and not
  in the plan. Build multi-arch or set `architecture = "X86_64"`.
- Scope an `ecs:RunTask` policy to the family with a `:*` revision wildcard, which this module's
  output does. A policy naming a single revision denies the call the moment the task definition is
  updated, and that reads as an unrelated regression on the next deploy.
- A Secrets Manager ARN may carry `:<json-key>:<version-stage>:<version-id>` so ECS injects one key
  of a JSON blob. IAM matches on the secret ARN, so the module truncates the ARN for the policy
  resource while the container's `valueFrom` keeps the full reference. An SSM ARN carries no such
  suffix and needs `ssm:GetParameters` rather than `secretsmanager:GetSecretValue`; the module picks
  the action per ARN.
- A secret encrypted with a customer-managed KMS key needs `kms:Decrypt` on the execution role as
  well. The derived grant covers the secret read alone, so add the key grant through
  `execution_role_policy_statements`.
- A missing secret grant fails the task at startup with a `ResourceInitializationError` naming the
  secret, which reads as a missing secret rather than a missing permission.
- Nothing here assumes private networking. `awsvpc` is the only mode Fargate supports, and a task
  launched in a public subnet with `AssignPublicIp = "ENABLED"` reaches ECR, Secrets Manager and
  CloudWatch Logs over the internet gateway with no NAT and no VPC endpoints. In a private subnet
  the same task needs a NAT gateway or interface endpoints, or it fails to pull the image. The
  subnets, security groups and public-IP flag are the caller's to set on the `RunTask` call, not
  inputs here.
- Container Insights is off by default and that is a cost decision: it bills per observed metric,
  and a cluster of short on-demand tasks generates a metric bill out of proportion to what it
  reports. `enhanced` is per-task and costs more than `enabled`.
- Fargate accepts only certain `cpu` and `memory` pairs. The module validates each value on its own
  but cannot validate the pair, so a legal `cpu` with an illegal `memory` for it is rejected at
  apply by the API.
- `ephemeral_storage_size` starts at 21 GiB, because 20 is the implicit default rather than a
  settable size. A task that clones a large repository fills the default and fails mid-run with no
  disk space, which is not obviously a storage problem from the logs.
- `environment` and `secrets` are rendered sorted by name. A map has no order of its own, so an
  unsorted render churns the container definition JSON and shows a diff on a task nothing changed
  about. For the same reason a task may not name one variable in both maps: ECS rejects the
  definition rather than picking a winner.
- Every change to a task definition creates a new revision and leaves the old ones in place;
  Terraform does not deregister them. A caller pinning `task_definition_arns` gets the exact
  revision Terraform last created, while `task_definition_family_arns` takes the latest active one.
- The container definition uses camelCase keys. A snake_case key is ignored by ECS rather than
  rejected, so a hand-written override that misspells one silently does nothing.
