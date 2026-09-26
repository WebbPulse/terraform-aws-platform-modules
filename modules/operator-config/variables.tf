variable "name_prefix" {
  description = "Estate prefix the parameter is named under, for example carmodpicker-staging, which gives /carmodpicker-staging/config. No leading or trailing slash."
  type        = string
  default     = null

  validation {
    condition     = var.name_prefix == null || can(regex("^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$", var.name_prefix))
    error_message = "name_prefix must be letters, digits and _ . - in segments joined by /, with no leading or trailing slash."
  }
}

variable "name" {
  description = "Full parameter name, overriding name_prefix outright. Must start with a slash."
  type        = string
  default     = null

  validation {
    condition     = var.name == null || can(regex("^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$", var.name))
    error_message = "name must start with a slash and hold letters, digits and _ . - in segments joined by /."
  }

  validation {
    condition     = var.name != null || var.name_prefix != null
    error_message = "Set name_prefix, or name to override it."
  }
}

variable "description" {
  description = "Description shown on the parameter."
  type        = string
  default     = "Operator-owned JSON object of private non-secret config read by Terraform. Terraform seeds it once and never writes it again."
}

variable "tags" {
  description = "Tags on the parameter, on top of the provider default_tags."
  type        = map(string)
  default     = {}
}
