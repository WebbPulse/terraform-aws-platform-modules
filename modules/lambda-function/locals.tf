locals {
  role_name      = coalesce(var.role_name, "${var.function_name}-role")
  log_group_name = coalesce(var.log_group_name, "/aws/lambda/${var.function_name}")
}
