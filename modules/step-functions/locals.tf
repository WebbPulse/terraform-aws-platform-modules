locals {
  definition = length(var.definition_substitutions) > 0 ? templatestring(var.definition, var.definition_substitutions) : var.definition

  role_name      = coalesce(var.role_name, "${var.name}-role")
  log_group_name = coalesce(var.log_group_name, "/aws/vendedlogs/states/${var.name}")

  attach_xray_write_policy = var.tracing_enabled && var.attach_xray_write_policy

  policy_statements = [
    for s in var.policy_statements : merge(
      s.sid == null ? {} : { Sid = s.sid },
      { Effect = s.effect },
      s.actions == null ? {} : { Action = jsondecode(length(s.actions) == 1 ? jsonencode(s.actions[0]) : jsonencode(s.actions)) },
      s.not_actions == null ? {} : { NotAction = jsondecode(length(s.not_actions) == 1 ? jsonencode(s.not_actions[0]) : jsonencode(s.not_actions)) },
      s.resources == null ? {} : { Resource = jsondecode(length(s.resources) == 1 ? jsonencode(s.resources[0]) : jsonencode(s.resources)) },
      s.not_resources == null ? {} : { NotResource = jsondecode(length(s.not_resources) == 1 ? jsonencode(s.not_resources[0]) : jsonencode(s.not_resources)) },
      s.condition == null ? {} : {
        Condition = {
          for op, kv in s.condition : op => {
            for k, v in kv : k => jsondecode(length(v) == 1 ? jsonencode(v[0]) : jsonencode(v))
          }
        }
      },
    )
  ]

  state_machine_arn = aws_sfn_state_machine.this.arn

  execution_arn_wildcard = replace(
    replace(local.state_machine_arn, ":stateMachine:", ":execution:"),
    "/:execution:(.*)$/",
    ":execution:$1:*",
  )

  caller_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartExecution"
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = local.state_machine_arn
      },
      {
        Sid      = "DescribeAndStopExecution"
        Effect   = "Allow"
        Action   = ["states:DescribeExecution", "states:StopExecution"]
        Resource = local.execution_arn_wildcard
      },
      {
        Sid    = "SendTaskOutcome"
        Effect = "Allow"
        Action = [
          "states:SendTaskFailure",
          "states:SendTaskHeartbeat",
          "states:SendTaskSuccess",
        ]
        Resource = "*"
      },
    ]
  })
}
