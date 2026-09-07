output "zone_id" {
  description = "Hosted zone id of the child zone, null when enabled is false. Point every record in the zone at this."
  value       = one(aws_route53_zone.this[*].zone_id)
}

output "zone_arn" {
  description = "ARN of the hosted zone, null when enabled is false."
  value       = one(aws_route53_zone.this[*].arn)
}

output "zone_name" {
  description = "Name of the hosted zone as stored by Route 53 (no trailing dot), null when enabled is false."
  value       = one(aws_route53_zone.this[*].name)
}

output "name_servers" {
  description = "Name servers Route 53 assigned to the zone; the delegation record in the parent points at these. null when enabled is false."
  value       = one(aws_route53_zone.this[*].name_servers)
}

output "delegation_record_fqdn" {
  description = "FQDN of the NS delegation record written into the parent zone, null when the module did not delegate. Reading it makes a resource depend on the delegation; for a depends_on list use the module address itself, depends_on = [module.<name>], since depends_on cannot reference an output."
  value       = one(aws_route53_record.delegation[*].fqdn)
}

output "delegation_record_id" {
  description = "Id of the NS delegation record in the parent zone (<parent_zone_id>_<zone_name>_NS), null when the module did not delegate."
  value       = one(aws_route53_record.delegation[*].id)
}
