terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
    }
  }
}

variable "http_api_alarms_enabled" {
  description = "Passed through to the module under test."
  type        = bool
  default     = null
}

variable "lambda_alarms_enabled" {
  description = "Passed through to the module under test."
  type        = bool
  default     = null
}

variable "lambda_errors_alarm_enabled" {
  description = "Passed through to the module under test."
  type        = bool
  default     = null
}

variable "alarms" {
  description = "Passed through to the module under test."
  type        = any
  default     = {}
}

resource "aws_apigatewayv2_api" "api" {
  name          = "example-test-api"
  protocol_type = "HTTP"
}

resource "aws_sns_topic" "names" {
  name = "example-test-names"
}

module "alarms" {
  source = "../../.."

  name_prefix = "example-test"
  alarms      = var.alarms

  http_api_id             = aws_apigatewayv2_api.api.id
  http_api_alarms_enabled = var.http_api_alarms_enabled

  lambda_function_name  = aws_sns_topic.names.id
  lambda_alarms_enabled = var.lambda_alarms_enabled

  lambda_errors_alarm_function_name = aws_sns_topic.names.id
  lambda_errors_alarm_enabled       = var.lambda_errors_alarm_enabled
}

output "api_alarm_count" {
  description = "Number of HTTP API alarms planned."
  value       = length(module.alarms.api_alarm_names)
}

output "lambda_alarm_names" {
  description = "Names of every Lambda alarm planned."
  value       = module.alarms.lambda_alarm_names
}
