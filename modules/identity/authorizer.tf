# ---------------------------------------------------------------------------
# The JWT authorizer.
#
# `issuer` and `audience` are the two things it validates beyond the signature, and both come from
# the same module inputs the identity function is configured from, so the gateway and the signer
# cannot disagree about either. A mismatch presents as every request being denied with nothing in
# any log to say why.
#
# ORDERING, WHICH IS THE REASON THIS IS A MODULE RATHER THAN FOUR RESOURCES A CONSUMER WIRES UP.
#
# CreateAuthorizer on an HTTP API validates the issuer synchronously: API Gateway fetches
# <issuer>/.well-known/openid-configuration during the create call and rejects it with
#
#     BadRequestException: ... Issuer must have a valid discovery endpoint ended with
#     '/.well-known/openid-configuration'
#
# when it does not get a discovery document back. The AWS documentation does not say so anywhere;
# it was learned from a failed apply on Portfolio's M0 spike. So two things must already be true
# when this resource is created, and neither is implied by anything it references:
#
#  1. The identity function is serving the discovery document and the JWKS.
#  2. The two `.well-known` routes exist on the API and answer ANONYMOUSLY. They cannot sit behind
#     an authorizer of any kind, because API Gateway's own validator fetches them from outside with
#     no credentials of ours. On an API fronted by the staging access gate that means
#     authorization_type = "NONE" on exactly those two routes.
#
# authorizer_depends_on is how a consumer expresses both. It takes whatever values stand for "the
# routes and the function exist", usually the whole http-api and lambda modules, and this resource
# waits on them.
#
# depends_on orders Terraform's API calls and not their effects, which is the gap
# wait_for_discovery_document closes. Three separate lags sit between "CreateRoute returned 201"
# and "a request from API Gateway's own validator gets a document back": an auto_deploy stage
# deploys a new route asynchronously, UpdateFunctionConfiguration returns while LastUpdateStatus is
# still InProgress, and a container image function under the Lambda Web Adapter takes seconds to
# cold start. Any one of them makes CreateAuthorizer fetch a 404, and the failure is the same
# BadRequestException as having no route at all, with nothing to say which of the two it was.
#
# PROTECTED ROUTES ARE NOT CREATED HERE, and that is deliberate rather than an omission. A route
# naming this authorizer has to be created after it, while the discovery routes have to be created
# before it. Putting both in one for_each collapses the two orderings into one and Terraform
# refuses the graph: the API module would depend on the authorizer, which depends on the API
# module. So the module hands back authorizer_id and the consumer attaches it to the routes it
# protects, either through the http-api module's per-route authorizer_id or as standalone routes.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "identity_jwt" {
  count = var.http_api_id == null ? 0 : 1

  api_id           = var.http_api_id
  name             = local.authorizer_name
  authorizer_type  = "JWT"
  identity_sources = var.authorizer_identity_sources

  jwt_configuration {
    issuer   = var.issuer
    audience = coalesce(var.authorizer_audiences, [var.audience])
  }

  depends_on = [terraform_data.discovery_document_ready]
}

# The wait between the routes and the authorizer.
#
# This polls the real URL from wherever Terraform runs, until it answers 2xx, and fails the apply if
# it never does. It is a poll rather than a sleep because a sleep long enough to be safe is longer
# than the wait usually needs to be, and a sleep short enough to be quick is not safe.
#
# Without it a spurious failure and a real misconfiguration are indistinguishable, and the recovery
# for the spurious one is to run the apply again and hope.
#
# The trigger is the issuer, so the poll runs again if the issuer ever changes and is skipped on an
# apply that changes neither it nor the attempt budget. What this resource asserts is that this
# exact URL answers.
#
# curl has to be on the machine running Terraform, which it is on the HCP Terraform worker image.
# A consumer running somewhere without it, or applying from a network that cannot reach the issuer,
# sets wait_for_discovery_document = false and takes responsibility for the ordering itself.
resource "terraform_data" "discovery_document_ready" {
  count = var.http_api_id != null && var.wait_for_discovery_document ? 1 : 0

  triggers_replace = {
    issuer   = var.issuer
    attempts = var.discovery_document_attempts
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      url="${var.issuer}/.well-known/openid-configuration"
      for attempt in $(seq 1 ${var.discovery_document_attempts}); do
        if curl -fsS --max-time 10 "$url" > /dev/null; then
          echo "discovery document served after $attempt attempt(s): $url"
          exit 0
        fi
        echo "attempt $attempt: no discovery document yet at $url"
        sleep 1
      done
      echo "gave up after ${var.discovery_document_attempts} attempts: $url never returned 2xx." >&2
      echo "API Gateway CreateAuthorizer fetches this URL and will fail without it." >&2
      exit 1
    EOT
  }

  depends_on = [var.authorizer_depends_on]
}
