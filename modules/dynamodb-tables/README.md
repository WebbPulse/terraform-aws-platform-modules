# terraform-aws-dynamodb-tables

An application's whole DynamoDB layer as one module block: a map of tables, on-demand billing, and
the two switches an estate actually varies between environments, continuous backups and deletion
protection. One `aws_dynamodb_table` per entry, keyed by the short name the application knows the
table by, so a new table is one more entry in a map rather than another copy of a 40-line resource.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/dynamodb-tables`.
Both application estates were carrying a hand-written `for_each` over `aws_dynamodb_table` in
`terraform/dynamodb.tf`; the module reproduces those tables exactly so adopting it is a set of
`moved` blocks and an empty plan. See [Adoption](#adoption).

## How it works

```
var.tables  =  { <key> = { attributes, hash_key, range_key?, global_secondary_indexes?,
                           ttl_attribute?, point_in_time_recovery?, deletion_protection?, tags? } }
   │
   │  name = "${var.name_prefix}-${key}"
   ▼
aws_dynamodb_table.this[<key>]
   ├─ billing_mode  PAY_PER_REQUEST
   ├─ attribute                one per entry in attributes          (a set, order does not matter)
   ├─ global_secondary_index   one per entry in the index list      (a set)
   ├─ ttl                      only when ttl_attribute is set
   ├─ point_in_time_recovery   table override, else var.point_in_time_recovery
   ├─ deletion_protection_enabled  table override, else var.deletion_protection
   └─ tags                     Name (optional) < var.tags < the table's own tags
   ▼
outputs: table_names, table_arns, table_arns_list, stream_arns, tables
```

- **Keys are the contract.** The map key is the short name, and it survives into every output and
  into the resource address. An application reads `module.<name>.table_names` into its Lambda
  environment and never rebuilds a table name from a prefix. Because the key is the `for_each` key,
  adopting an existing `for_each` resource is a rename with the keys unchanged.
- **Attributes are a list of objects.** `[{ name = "id", type = "S" }]`, not a map. A map of
  `name => type` reads more tidily but sorts its entries, and it cannot express an application that
  wants a stable authored order. The provider stores `attribute` as a set either way, so neither
  form reaches the plan, and the list form is the one that matches what DynamoDB's own API takes.
- **Two switches, both overridable.** `point_in_time_recovery` and `deletion_protection` are
  module-wide inputs (usually `var.environment == "production"`), and any single table can override
  either with a value of its own. A table of short-lived rows with a TTL says
  `point_in_time_recovery = false` and stays off in production too.
- **Validation catches at plan time what DynamoDB would reject at apply time.** Every key names an
  attribute that exists, attribute types are `S`/`N`/`B`, index names are unique within a table,
  and `non_key_attributes` is present exactly when `projection_type` is `INCLUDE`.

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `tables` | Map of short key to table definition, see below | required |
| `name_prefix` | Prefix joined to each key with a hyphen to form the table name; empty uses the key verbatim | `""` |
| `point_in_time_recovery` | Module-wide continuous backups; a table can override | `false` |
| `deletion_protection` | Module-wide deletion protection; a table can override | `false` |
| `name_tag` | Add a `Name` tag equal to the table's full name | `false` |
| `tags` | Tags on every table, on top of `default_tags`; empty is passed as `null` | `{}` |
| `billing_mode` | `PAY_PER_REQUEST` or `PROVISIONED` | `PAY_PER_REQUEST` |
| `read_capacity` / `write_capacity` | Table capacity under `PROVISIONED` | `null` |
| `server_side_encryption` | `{ enabled, kms_key_arn? }`; `null` omits the block and DynamoDB uses the AWS owned key | `null` |
| `stream_enabled` | Turn on the table stream | `false` |
| `stream_view_type` | `KEYS_ONLY`, `NEW_IMAGE`, `OLD_IMAGE` or `NEW_AND_OLD_IMAGES`; required when the stream is on | `null` |

Each entry in `tables`:

| Field | Description | Default |
| --- | --- | --- |
| `attributes` | `[{ name, type }]` for every key attribute the table or an index uses | required |
| `hash_key` | Partition key attribute name | required |
| `range_key` | Sort key attribute name | `null` |
| `global_secondary_indexes` | `[{ name, hash_key, range_key?, projection_type?, non_key_attributes?, read_capacity?, write_capacity? }]` | `[]` |
| `ttl_attribute` | Attribute holding the expiry epoch seconds | `null` |
| `point_in_time_recovery` | Per-table override of the module-wide value | `null` |
| `deletion_protection` | Per-table override of the module-wide value | `null` |
| `stream_view_type` | Turns this table's stream on by itself; one of the four view types | `null` |
| `tags` | Extra tags for this table | `{}` |

`projection_type` defaults to `ALL` on an index that does not name one.

## Streams

Two ways to turn a stream on, and the difference matters once a call creates more than one table.

The module-wide `stream_enabled` and `stream_view_type` are one setting for every table the call
creates. That is the right shape when every table wants a stream and the wrong one when only some
do, because there is no way to exempt a table from it.

A table's own `stream_view_type` is the per-table form. A non-null value turns that table's stream
on and sets what its records carry, and it wins over the module-wide pair. `null`, the default,
falls back to that pair, so a consumer that sets no per-table value plans exactly what it has
today. Enabling a stream on a table that already exists is an in-place `UpdateTable`; it does not
replace the table.

```hcl
tables = {
  users = {
    attributes       = [{ name = "id", type = "S" }]
    hash_key         = "id"
    stream_view_type = "NEW_AND_OLD_IMAGES"
  }

  # No stream: no per-table value and the module-wide default is off.
  sessions = {
    attributes = [{ name = "id", type = "S" }]
    hash_key   = "id"
  }
}
```

**Pick the view type once.** DynamoDB does not allow editing a `StreamViewType` after the stream
exists. Changing it disables the stream and creates a new one, which mints a new stream ARN and
detaches every event source mapping and EventBridge pipe that was reading the old one. Choose for
what the eventual consumer needs: a handler that has to see what a deleted item held needs
`NEW_AND_OLD_IMAGES`, and it cannot be added later without that break. See
[Change data capture for DynamoDB Streams](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html).

Stream records live for 24 hours, so a consumer that falls further behind than that loses events
rather than catching up.

## Outputs

| Name | Description |
| --- | --- |
| `table_names` | Short key to full table name; the map a Lambda takes as environment variables |
| `table_arns` | Short key to table ARN |
| `table_arns_list` | Every ARN as a list sorted by key, for an IAM resource list |
| `stream_arns` | Short key to latest stream ARN, `null` without a stream |
| `tables` | Short key to `{ name, arn, id, stream_arn, stream_label }` |

Granting item level access to everything the module owns:

```hcl
resources = concat(
  module.dynamodb.table_arns_list,
  [for arn in module.dynamodb.table_arns_list : "${arn}/index/*"],
)
```

## Adoption

Both estates are adopted the same way: keep the data that describes the tables where it already
lives, reshape it if needed so it matches the module's input, and rename the resource with `moved`
blocks. The keys do not change, so table names, keys, indexes, TTL, tags and both switches come out
of the module exactly as they are in state. Land it on `staging` first and read the speculative
plan: it must show only the moves and `0 to add, 0 to change, 0 to destroy`.

The module ships from 1.6.0, so consumers need `version = "~> 1.6"`.

### CarModPicker

CarModPicker's `dynamodb_tables.json` is generated from the backend's table definitions and already
uses the module's shape: `attributes` is a list of `{ name, type }`, `range_key` sits on the table,
and `global_secondary_indexes` and `ttl_attribute` are named the same. The JSON is passed straight
through and the generator does not change. Replace the body of `terraform/dynamodb.tf` with:

```hcl
locals {
  dynamodb_tables = jsondecode(file("${path.module}/dynamodb_tables.json"))
}

module "dynamodb" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/dynamodb-tables"
  version = "~> 1.6"

  name_prefix = local.prefix
  tables      = local.dynamodb_tables

  point_in_time_recovery = var.environment == "production"
  deletion_protection    = var.environment == "production"
  name_tag               = true
}

moved {
  from = aws_dynamodb_table.tables
  to   = module.dynamodb.aws_dynamodb_table.this
}
```

One `moved` block covers all 25 tables: moving a `for_each` resource to another `for_each` resource
by its bare address carries every instance key across.

`name_tag = true` reproduces the `tags = { Name = "${local.prefix}-${each.key}" }` the hand-written
resource sets. Two other files reference the tables and are repointed at the module's outputs:

```hcl
# monitoring.tf, the per-table throttle alarm. The module's tables output is keyed the same way and
# each value carries name, so each.value.name in the alarm body is unchanged.
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  for_each = module.dynamodb.tables
  ...
}

# outputs.tf
output "dynamodb_table_names" {
  description = "DynamoDB table names keyed by table suffix"
  value       = module.dynamodb.table_names
}
```

The Lambda's IAM policy grants on `table/${local.prefix}-*` by wildcard, so it needs no change.

### WebbPulse-Portfolio

The Portfolio's tables are described by inline locals in a shape of their own: `attributes` is a
`name => type` map, indexes are called `gsis`, TTL is `ttl` and the per-table backup flag is `pitr`.
The module normalises on the object-list form, so the locals are reshaped in the consumer. That is a
change to the input data only; every table name, key, index, TTL and flag is the same value it is
today, and the plan is empty.

Replace `terraform/dynamodb.tf` with:

```hcl
locals {
  dynamodb_entity_tables = ["users", "categories", "posts", "projects", "experience", "skills", "education", "certifications", "site-content"]

  dynamodb_tables = merge(
    {
      for entity in local.dynamodb_entity_tables : entity => {
        hash_key   = "id"
        attributes = [{ name = "id", type = "N" }]
      }
    },
    {
      posts = {
        hash_key = "id"
        attributes = [
          { name = "id", type = "N" },
          { name = "published_flag", type = "S" },
          { name = "published_at", type = "S" },
          { name = "category_id", type = "N" },
        ]
        global_secondary_indexes = [
          { name = "published-index", hash_key = "published_flag", range_key = "published_at", projection_type = "ALL" },
          { name = "category-index", hash_key = "category_id", range_key = "id", projection_type = "KEYS_ONLY" },
        ]
      }
      meta = {
        hash_key               = "pk"
        attributes             = [{ name = "pk", type = "S" }]
        ttl_attribute          = "ttl"
        point_in_time_recovery = false
      }
    },
  )
}

module "dynamodb" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/dynamodb-tables"
  version = "~> 1.6"

  name_prefix = local.prefix
  tables      = local.dynamodb_tables

  point_in_time_recovery = true
  deletion_protection    = var.environment == "production"
}

moved {
  from = aws_dynamodb_table.this["users"]
  to   = module.dynamodb.aws_dynamodb_table.this["users"]
}

moved {
  from = aws_dynamodb_table.this["categories"]
  to   = module.dynamodb.aws_dynamodb_table.this["categories"]
}

moved {
  from = aws_dynamodb_table.this["posts"]
  to   = module.dynamodb.aws_dynamodb_table.this["posts"]
}

moved {
  from = aws_dynamodb_table.this["projects"]
  to   = module.dynamodb.aws_dynamodb_table.this["projects"]
}

moved {
  from = aws_dynamodb_table.this["experience"]
  to   = module.dynamodb.aws_dynamodb_table.this["experience"]
}

moved {
  from = aws_dynamodb_table.this["skills"]
  to   = module.dynamodb.aws_dynamodb_table.this["skills"]
}

moved {
  from = aws_dynamodb_table.this["education"]
  to   = module.dynamodb.aws_dynamodb_table.this["education"]
}

moved {
  from = aws_dynamodb_table.this["certifications"]
  to   = module.dynamodb.aws_dynamodb_table.this["certifications"]
}

moved {
  from = aws_dynamodb_table.this["site-content"]
  to   = module.dynamodb.aws_dynamodb_table.this["site-content"]
}

moved {
  from = aws_dynamodb_table.this["meta"]
  to   = module.dynamodb.aws_dynamodb_table.this["meta"]
}
```

The moves are written per key here because the old and the new resource share the name `this`.
`moved { from = aws_dynamodb_table.this, to = module.dynamodb.aws_dynamodb_table.this }` reads as a
move of the root resource into the module, which is what is wanted, but writing it out per key keeps
the two `this` addresses unambiguous to anyone reading the file, and it is the form to use whenever a
key is being renamed at the same time.

The reshaping is mechanical: `attributes = { id = "N" }` becomes
`attributes = [{ name = "id", type = "N" }]`, `gsis` becomes `global_secondary_indexes`, `ttl`
becomes `ttl_attribute`, and `pitr` becomes `point_in_time_recovery`. Nine of the ten tables had
`pitr = true`, so that becomes the module-wide `point_in_time_recovery = true` and only `meta`
carries an override. The `gsis = []`, `ttl = null` and `pitr = true` lines on the entity tables all
fall away into module defaults.

Two other files are repointed:

```hcl
# lambda.tf
locals {
  lambda_function_name = "${local.prefix}-api"
  lambda_table_arns    = module.dynamodb.table_arns_list
  lambda_index_arns    = [for arn in module.dynamodb.table_arns_list : "${arn}/index/*"]
}

# outputs.tf
output "dynamodb_table_names" {
  description = "DynamoDB table names keyed by entity"
  value       = module.dynamodb.table_names
}
```

`table_arns_list` is sorted by table key. The list it replaces came from a `for` over a map, which
Terraform also yields in key order, so the rendered IAM policy document is unchanged.

### What the module reproduces, attribute by attribute

| Attribute | CarModPicker today | Portfolio today | Module |
| --- | --- | --- | --- |
| `name` | `${local.prefix}-${key}` | `${local.prefix}-${key}` | `name_prefix` plus the key |
| `billing_mode` | `PAY_PER_REQUEST` | `PAY_PER_REQUEST` | default |
| `hash_key`, `range_key` | both from the JSON | `hash_key` only | `hash_key`, `range_key` per table |
| `attribute` | list of `{ name, type }` | map of `name => type` | list of `{ name, type }`, a set in state either way |
| `global_secondary_index` | from the JSON | `gsis` | `global_secondary_indexes` |
| `ttl` | block only when `ttl_attribute` is set | same, from `ttl` | same, from `ttl_attribute` |
| `point_in_time_recovery` | `var.environment == "production"` | per table `pitr` | module-wide input plus per-table override |
| `deletion_protection_enabled` | `var.environment == "production"` | `var.environment == "production"` | `deletion_protection` |
| `tags` | `{ Name = <full name> }` | none | `name_tag = true` for CarModPicker, `null` for the Portfolio |

## Known limits

- On-demand billing is the path the module is written for. `PROVISIONED` is accepted and the
  capacity inputs are wired through, but no autoscaling target or policy is created; that is a
  separate concern and belongs outside the module.
- One region. Global tables and replicas are not modelled. A table that needs replicas outgrows
  this module.
- `import_table`, `restore_source_name` and on-demand throughput overrides are not exposed. A table
  seeded from S3 or restored from a backup is created outside the module and, once it exists, can
  be adopted into it with an `import` block.
- The stream settings and `server_side_encryption` are module-wide rather than per table, because
  no consumer needs them to vary and a per-table version would widen the input object for nobody.
  Moving either into the per-table object later is a backwards compatible change.
