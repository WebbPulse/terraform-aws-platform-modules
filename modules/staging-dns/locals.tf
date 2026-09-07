locals {
  zone_count       = var.enabled ? 1 : 0
  delegation_count = var.enabled && var.delegate ? 1 : 0

  # An empty map and an unset attribute are the same thing to the provider, but passing null is the
  # form that is guaranteed to plan clean against a zone that was created without a tags argument.
  zone_tags = length(var.tags) > 0 ? var.tags : null
}
