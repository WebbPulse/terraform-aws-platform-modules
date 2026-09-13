# terraform-aws-dynamodb-tables

Creates one `aws_dynamodb_table` per entry in a map, keyed by the short name the application knows
the table by. On-demand billing by default, with continuous backups and deletion protection as
module-wide switches any single table can override.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/dynamodb-tables`.

## Usage

```hcl
module "dynamodb" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/dynamodb-tables"
  version = "~> 1.6"

  name_prefix = local.prefix

  tables = {
    users = {
      attributes = [{ name = "id", type = "S" }]
      hash_key   = "id"
    }

    posts = {
      attributes = [
        { name = "id", type = "N" },
        { name = "published_flag", type = "S" },
        { name = "published_at", type = "S" },
      ]
      hash_key = "id"
      global_secondary_indexes = [
        {
          name      = "published-index"
          hash_key  = "published_flag"
          range_key = "published_at"
        },
      ]
    }
  }

  point_in_time_recovery = var.environment == "production"
  deletion_protection    = var.environment == "production"
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `tables` | Map of short key to table definition; see the shape below | required |
| `name_prefix` | Joined to each key with a hyphen to form the table name; empty uses the key verbatim | `""` |
| `point_in_time_recovery` | Module-wide continuous backups; a table may override | `false` |
| `deletion_protection` | Module-wide deletion protection flag; a table may override | `false` |
| `billing_mode` | `PAY_PER_REQUEST` or `PROVISIONED` | `"PAY_PER_REQUEST"` |
| `read_capacity` | Table read capacity units under `PROVISIONED` | `null` |
| `write_capacity` | Table write capacity units under `PROVISIONED` | `null` |
| `server_side_encryption` | `{ enabled, kms_key_arn? }`; null omits the block and DynamoDB uses the AWS owned key | `null` |
| `stream_enabled` | Turn on the stream for every table in this call | `false` |
| `stream_view_type` | `KEYS_ONLY`, `NEW_IMAGE`, `OLD_IMAGE` or `NEW_AND_OLD_IMAGES`; required when `stream_enabled` | `null` |
| `name_tag` | Add a `Name` tag equal to the table's full name | `false` |
| `tags` | Tags on every table, on top of the provider `default_tags`; empty is passed as null | `{}` |

Each entry in `tables`:

```hcl
{
  attributes               = list(object({ name = string, type = string }))  # required, type S/N/B
  hash_key                 = string                                          # required
  range_key                = optional(string)                                # null
  global_secondary_indexes = optional(list(object({
    name               = string
    hash_key           = string
    range_key          = optional(string)
    projection_type    = optional(string, "ALL")
    non_key_attributes = optional(list(string))
    read_capacity      = optional(number)
    write_capacity     = optional(number)
  })), [])
  ttl_attribute          = optional(string)      # null
  point_in_time_recovery = optional(bool)        # null takes the module-wide value
  deletion_protection    = optional(bool)        # null takes the module-wide value
  stream_view_type       = optional(string)      # null takes stream_enabled / stream_view_type
  tags                   = optional(map(string), {})
}
```

## Outputs

| Name | Description |
| --- | --- |
| `tables` | Short key to `{ name, arn, id, stream_arn, stream_label }` |
| `table_names` | Short key to full table name, the map a Lambda takes as environment variables |
| `table_arns` | Short key to table ARN |
| `table_arns_list` | Every table ARN as a list sorted by key, for an IAM resource list |
| `stream_arns` | Short key to latest stream ARN, null on a table without a stream |

## Gotchas

- The map key is the `for_each` key and it reaches the table name, every output and the resource
  address. Renaming a key destroys and recreates the table; set `name` on the table instead.
- Deletion protection makes AWS refuse `DeleteTable`, so a `terraform destroy` or a key rename on a
  protected table fails at apply time until the flag is turned off in a prior apply.
- Turning point-in-time recovery on or off is an in-place update, but a table created without it has
  no backup history to restore from for the window before it was enabled.
- A stream's `StreamViewType` cannot be edited. Changing it disables the stream and creates a new
  one, minting a new stream ARN and detaching every event source mapping and pipe reading the old.
- Enabling a stream on an existing table is an in-place `UpdateTable` and does not replace it.
  Stream records live 24 hours, so a consumer further behind than that loses events.
- Changing a table's `hash_key` or `range_key`, or an index's keys or `projection_type`, forces
  replacement of the table or index; adding or removing a whole GSI is an online update instead.
- `non_key_attributes` must be set exactly when `projection_type` is `INCLUDE`, and every table and
  index key must appear in `attributes`; both are caught at plan time by validation.
- Index keys are written to the provider as a nested `key_schema` block, not the deprecated
  `hash_key` and `range_key` arguments. The `global_secondary_indexes` input is unchanged and still
  takes `hash_key` and `range_key`; the module translates them. The provider treats the swap as a
  no-op, so an existing index is neither replaced nor updated. This needs aws provider 6.32.1 or
  later, which the module's `required_providers` now enforces.
- `PROVISIONED` wires the capacity inputs through but creates no autoscaling target or policy.
- A users table feeding the identity module's purge mapping needs `stream_view_type` set here first:
  `stream_arns["users"]` is null until it is, and the mapping resolves the ARN at create time.
  `KEYS_ONLY` is enough, because that handler reads only the key of a `REMOVE` record.
- One region. Global tables, replicas, `import_table` and `restore_source_name` are not modelled.
