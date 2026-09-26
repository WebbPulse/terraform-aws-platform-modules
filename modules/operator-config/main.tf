locals {
  name = var.name != null ? var.name : "/${coalesce(var.name_prefix, "unset")}/config"
}

resource "aws_ssm_parameter" "this" {
  name           = local.name
  description    = var.description
  type           = "String"
  tier           = "Standard"
  insecure_value = "{}"
  tags           = var.tags

  lifecycle {
    ignore_changes = [insecure_value]
  }
}
