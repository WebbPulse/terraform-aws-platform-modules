locals {
  role_name      = coalesce(var.role_name, "${var.function_name}-role")
  log_group_name = coalesce(var.log_group_name, "/aws/lambda/${var.function_name}")

  environment_variables = merge(var.environment_variables, var.otel_environment_variables)

  # Active tracing without xray:PutTraceSegments is a function that samples invocations and then
  # drops every segment it tries to publish, with nothing in the logs to say so.
  attach_xray_write_policy = var.attach_xray_write_policy && var.tracing_mode == "Active"
}
