locals {
  zone_count       = var.enabled ? 1 : 0
  delegation_count = var.enabled && var.delegate ? 1 : 0

  zone_tags = length(var.tags) > 0 ? var.tags : null
}
