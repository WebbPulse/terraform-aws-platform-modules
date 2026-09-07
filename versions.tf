# The root of this repository is intentionally an empty module. Everything consumable lives under
# modules/<name> and is addressed as
#   app.terraform.io/WebbPulse/platform-modules/aws//modules/<name>
# A composite root module that wires the pieces into one application stack is the planned end
# state; until it exists, this file only pins the Terraform version the registry ingests.
terraform {
  required_version = ">= 1.10"
}
