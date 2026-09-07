output "tables" {
  description = "Every table the module created, keyed by the short key from var.tables. Each value carries name, arn, id, stream_arn and stream_label so a consumer can reach any of them without a second lookup."
  value = {
    for key, table in aws_dynamodb_table.this : key => {
      name         = table.name
      arn          = table.arn
      id           = table.id
      stream_arn   = table.stream_arn
      stream_label = table.stream_label
    }
  }
}

output "table_names" {
  description = "Short key to full table name. This is the map an application passes to its Lambda as an environment variable so the code never builds a table name from a prefix."
  value       = { for key, table in aws_dynamodb_table.this : key => table.name }
}

output "table_arns" {
  description = "Short key to table ARN. Grant with values(module.<name>.table_arns) plus the index wildcard, for example [for arn in values(module.<name>.table_arns) : \"<arn>/index/*\"]."
  value       = { for key, table in aws_dynamodb_table.this : key => table.arn }
}

output "table_arns_list" {
  description = "Every table ARN as a list, sorted by table key, ready to drop into an IAM policy resource list."
  value       = [for key in sort(keys(aws_dynamodb_table.this)) : aws_dynamodb_table.this[key].arn]
}

output "stream_arns" {
  description = "Short key to the table's latest stream ARN, null on a table without a stream. Use it as an event source mapping's event_source_arn."
  value       = { for key, table in aws_dynamodb_table.this : key => table.stream_arn }
}
