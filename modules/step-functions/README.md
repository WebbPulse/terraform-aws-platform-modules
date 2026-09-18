# terraform-aws-step-functions

Creates a Step Functions state machine from a caller-supplied Amazon States Language definition,
with its IAM execution role, its CloudWatch log group, and a ready-made policy for whoever starts
the executions.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/step-functions`.

## Usage

```hcl
module "run" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/step-functions"
  version = "~> 2.23"

  name = "example-staging-run"

  definition = file("${path.module}/run.asl.json")

  definition_substitutions = {
    ClusterArn            = module.tasks.cluster_arn
    PlanTaskDefinitionArn = module.tasks.task_definition_arns["plan"]
  }

  policy_statements = [
    {
      sid       = "RunPlanTask"
      actions   = ["ecs:RunTask"]
      resources = ["${module.tasks.task_definition_family_arns["plan"]}:*"]
      condition = {
        ArnEquals = { "ecs:cluster" = [module.tasks.cluster_arn] }
      }
    },
  ]

  log_retention_days = 14
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `name` | State machine name as-is, not a prefix; changing it replaces the machine | required |
| `definition` | Amazon States Language definition as a JSON string | required |
| `definition_substitutions` | Values for the `${key}` placeholders in `definition` | `{}` |
| `type` | `STANDARD` or `EXPRESS` | `"STANDARD"` |
| `role_name` | Execution role name, null for `<name>-role` | `null` |
| `role_path` | IAM path of the execution role; changing it replaces the role | `"/"` |
| `role_description` | Description on the execution role, null for none | `null` |
| `permissions_boundary_arn` | Permissions boundary policy ARN on the execution role | `null` |
| `role_tags` | Extra tags on the execution role only | `{}` |
| `policy_statements` | Statements of the role's inline work policy, one object per IAM statement | `[]` |
| `policy_name` | Name of the inline policy carrying `policy_statements` | `"work"` |
| `log_group_name` | Log group name, null for `/aws/vendedlogs/states/<name>` | `null` |
| `log_retention_days` | Retention in days, a value CloudWatch Logs accepts; 0 never expires | `14` |
| `log_group_kms_key_id` | KMS key ARN for the log group; null uses the service key | `null` |
| `log_group_tags` | Extra tags on the log group only | `{}` |
| `log_level` | `ALL`, `ERROR`, `FATAL` or `OFF` | `"ALL"` |
| `include_execution_data` | Log each state's input and output payloads | `true` |
| `tracing_enabled` | Enable X-Ray tracing for executions | `false` |
| `attach_xray_write_policy` | Attach the inline X-Ray write policy when tracing is on | `true` |
| `publish` | Publish a numbered version on every change | `false` |
| `tags` | Extra tags on the state machine only | `{}` |

A `policy_statements` entry takes `sid`, `effect`, one of `actions` or `not_actions`, one of
`resources` or `not_resources`, and an optional `condition` of operator to key to values. A
one-element list renders as a bare JSON string, which is how a hand-written policy is usually
spelled.

## Outputs

| Name | Description |
| --- | --- |
| `arn` | State machine ARN, the resource a `states:StartExecution` policy names |
| `name` | State machine name, for an alarm dimension |
| `state_machine_version_arn` | Version ARN for the current definition, empty unless `publish` is on |
| `role_arn` | Execution role ARN, for a policy naming the role as a principal |
| `role_name` | Execution role name, for an attachment outside the module |
| `role_id` | Execution role id, which is what `aws_iam_role_policy` takes as its `role` |
| `log_group_name` | Name of the state machine's log group |
| `log_group_arn` | ARN of the state machine's log group |
| `caller_policy_json` | Policy for a caller: start, describe and stop executions, and send task success, failure and heartbeat |
| `xray_write_policy_attached` | Whether the module attached its inline X-Ray write policy |

## Gotchas

- A `.sync` integration needs more than the obvious action. `arn:aws:states:::ecs:runTask.sync`
  makes the service create a managed EventBridge rule to learn the task finished, so the execution
  role needs `events:PutRule`, `events:PutTargets` and `events:DescribeRule` on
  `rule/StepFunctionsGetEventsForECSTaskRule` on top of `ecs:RunTask`. Without them the state fails
  immediately with an `EventBridge` permission error that never mentions Step Functions, and the
  same applies to the `.sync` forms of Batch, EMR and CodeBuild.
- A `.sync` state also needs `ecs:DescribeTasks` and `ecs:StopTask`: the first is how the poll
  learns the task ended, the second is what runs when the execution is aborted or the state times
  out. A machine granted only `ecs:RunTask` starts the task and then hangs until its timeout.
- `iam:PassRole` is the grant most often missed when a state launches an ECS task. `RunTask` hands
  ECS a task role and an execution role, which IAM treats as passing them, so `ecs:RunTask` alone
  is denied. The ecs-fargate module's `run_task_policy_json` already carries it.
- The logging destination must be the log group ARN with `:*` appended, which this module does for
  you. A bare log group ARN is rejected with an invalid-ARN error that does not name the suffix.
- Step Functions logs through vended log delivery, which the service sets up as the execution role
  rather than as itself, so the role needs `logs:CreateLogDelivery` and `logs:PutResourcePolicy`
  and friends. The module attaches these unconditionally, because without them `CreateStateMachine`
  fails outright rather than merely logging nothing.
- `log_level = "OFF"` is not the same as omitting the logging configuration: the block stays and
  nothing flows. The module leaves the destination null in that case, since the service rejects a
  configuration that names a destination while logging nothing.
- `include_execution_data` logs every state's input and output verbatim, and CloudWatch Logs has no
  redaction. A machine whose payloads carry anything sensitive should turn it off, at the cost of a
  failed run recording that a state failed without recording what it was given.
- The execution history expires after 90 days and cannot be extended. The log group is the durable
  record, which is why `log_level` defaults to `ALL` and retention is yours to set.
- An `EXPRESS` machine cannot use `.sync` or `waitForTaskToken`, is at-least-once rather than
  exactly-once, and is capped at five minutes. Changing `type` on an existing machine replaces it.
- `definition_substitutions` is applied by this module with `templatestring`, not by the provider:
  `aws_sfn_state_machine` has no such argument. A placeholder with no entry in the map reaches the
  service literally and fails the definition validation with a malformed-ARN error rather than a
  missing-substitution one. Substitution is textual, so a value carrying a bare quote corrupts the
  document; the module's post-substitution check catches that as invalid JSON rather than letting
  the service reject it at apply.
- A placeholder stands for a fragment of the JSON text, not for a string value, so it can take a
  number or an array. Write it unquoted for those, `"TimeoutSeconds": ${TimeoutSeconds}` or
  `"Subnets": ${SubnetIdsJson}`, and pass `tostring(...)` or `jsonencode(...)` from the caller.
  This works because the module validates the definition after substituting it: the raw string with
  an unquoted `${...}` in a numeric position is not valid JSON on its own, and validating it first
  rejected every numeric and list substitution a caller wanted to make. The check lives on the
  state machine resource as a `precondition` rather than on the variable, since a variable
  `validation` cannot see another input.
- The provider validates the definition against the live service at plan time, so a plan needs
  real credentials. A `terraform test` run against mock credentials has to override
  `aws_sfn_state_machine` with `override_during = plan`, which is what this module's own tests do.
- Tracing without the X-Ray grant emits nothing and reports no error on the execution. Step
  Functions also makes its own sampling decision, so the role needs `xray:GetSamplingRules` and
  `xray:GetSamplingTargets` on top of the two publish actions; a Lambda-shaped X-Ray policy is not
  enough.
- The three task-token actions in `caller_policy_json` sit on `Resource "*"` because they authorize
  against the opaque token rather than against any ARN. Scoping them to the state machine denies
  every callback.
