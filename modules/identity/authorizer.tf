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
