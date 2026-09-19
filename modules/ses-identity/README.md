# terraform-aws-ses-identity

A product's transactional sending setup in SES v2: a configuration set with reputation, sending,
optional TLS and optional VDM options, one sending identity (a domain with Easy DKIM, or a single
address), an optional custom MAIL FROM, feedback forwarding, an optional SNS event destination, the
Easy DKIM and DMARC records, and the explicitly listed recipient identities a sandboxed account
needs in order to send anywhere at all.

The module authors resources only. **It never requests SES sandbox removal or production access**,
and it has no input that could: those are handled out of band by the account owner. Recipient
identities are created from `verified_recipients` and from nothing else, so an account cannot grow
a verified recipient by accident.

Consumed as `app.terraform.io/WebbPulse/platform-modules/aws//modules/ses-identity`.

## Usage

```hcl
module "ses" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ses-identity"
  version = "~> 2.27"

  configuration_set_name = "example-transactional"

  domain           = "example.com"
  mail_from_domain = "bounce.example.com"

  verified_recipients = var.ses_verified_recipients
}

resource "aws_iam_role_policy" "api_ses" {
  name   = "api-ses"
  role   = module.api_lambda.role_id
  policy = module.ses.send_policy_json
}
```

## Inputs

| Name | Description | Default |
| --- | --- | --- |
| `configuration_set_name` | Configuration set every send names, and the metric dimension | required |
| `domain` | Sending domain verified with Easy DKIM; null sends from `sender_address` | `null` |
| `sender_address` | Single address verified instead of a domain; exactly one of the two | `null` |
| `dkim_signing_key_length` | `RSA_1024_BIT` or `RSA_2048_BIT` on the domain identity | `"RSA_2048_BIT"` |
| `mail_from_domain` | Custom MAIL FROM subdomain; null keeps the SES default | `null` |
| `behavior_on_mx_failure` | `USE_DEFAULT_VALUE` or `REJECT_MESSAGE` | `"USE_DEFAULT_VALUE"` |
| `email_forwarding_enabled` | Forward bounces to the identity's own address | `false` |
| `set_feedback_attributes` | Manage the feedback attribute at all | `true` |
| `reputation_metrics_enabled` | Publish per configuration set reputation metrics | `true` |
| `sending_enabled` | Allow sending through this configuration set | `true` |
| `tls_policy` | `REQUIRE` or `OPTIONAL`; null omits the delivery options block | `null` |
| `vdm_options_enabled` | Write the configuration set's `vdm_options` block | `false` |
| `manage_account_vdm_attributes` | Manage the account wide VDM attributes | `false` |
| `notification_topic_arn` | SNS topic the event destination publishes to; null creates none | `null` |
| `notification_event_types` | Event types sent to that topic | `["BOUNCE", "COMPLAINT", "DELIVERY_DELAY"]` |
| `event_destination_name` | Name of the created event destination | `"sns-notifications"` |
| `create_dkim_records` | Write the three Easy DKIM CNAMEs | `false` |
| `dkim_records_zone_id` | Hosted zone the DKIM and DMARC records go in | `null` |
| `dkim_record_ttl` | TTL on the DKIM CNAMEs | `1800` |
| `dmarc_record` | DMARC policy string published at `_dmarc.<domain>`; null writes none | `null` |
| `dmarc_record_ttl` | TTL on the DMARC TXT record | `1800` |
| `verified_recipients` | Addresses verified as recipient identities, explicit list | `[]` |
| `recipient_tags` | Tags on each recipient identity, merged over `tags` | `{}` |
| `tags` | Tags on the configuration set and the sending identity | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `configuration_set_name` | Name of the configuration set |
| `configuration_set_arn` | ARN of the configuration set |
| `identity_arn` | ARN of the sending identity, domain or address |
| `identity_name` | The verified identity itself |
| `dkim_tokens` | Easy DKIM tokens, empty on a sender address identity |
| `mail_from_domain` | Custom MAIL FROM in force, null on the SES default |
| `send_policy_statements` | `ses:SendEmail` grant as a statement list |
| `send_policy_json` | The same grant as a complete policy document |
| `verified_recipient_arns` | Recipient identity ARNs keyed by address |

## Gotchas

- **Sandbox and production access are the owner's, not this module's.** Nothing here calls
  `PutAccountDetails` or opens a case. In a sandboxed account SES will only deliver to a verified
  recipient, which is what `verified_recipients` is for, and an account with production access
  should carry an empty list rather than a stale one. A recipient identity is a real SES object: it
  sends a verification email to the address on create, and removing an entry deletes the identity.
- `domain` and `sender_address` are mutually exclusive and one is required. The check is a
  `precondition` on the configuration set, so it fails at plan time naming both.
- A domain identity's DKIM tokens only exist after the create, so `create_dkim_records` writes the
  CNAMEs in the same run that mints them. The records are in this module only when
  `dkim_records_zone_id` is set; a product whose zone lives in another account writes them itself
  from the `dkim_tokens` output through its own `aws.dns` provider, because a module cannot take a
  provider alias conditionally.
- `manage_account_vdm_attributes` and `aws_sesv2_account_vdm_attributes` are account scoped, not
  configuration set scoped. Exactly one module instance per account and region may set it true, and
  two that do will fight on every plan. It defaults to false for that reason, and
  `vdm_options_enabled` (which is per configuration set) is the one most products want.
- `tls_policy` defaults to null, which leaves the `delivery_options` block out entirely rather than
  writing the service default into it. Setting it to `OPTIONAL` is not the same as leaving it null:
  one is a managed attribute that will be corrected on drift, the other is unmanaged.
- The `send_policy_json` output grants `ses:SendEmail` on the identity and the configuration set
  together. Both resources are needed: a grant naming only the identity is denied the moment the
  send names a configuration set, with an AccessDenied that names neither.
- **Adopting this module from a hand-written `ses.tf` needs `moved` blocks.** The configuration set
  is `this` where the originals variously used `transactional` and `identity`, and the counted
  identity resources keep their `[0]`:

  ```hcl
  moved {
    from = aws_sesv2_configuration_set.transactional
    to   = module.ses.aws_sesv2_configuration_set.this
  }

  moved {
    from = aws_sesv2_email_identity.domain[0]
    to   = module.ses.aws_sesv2_email_identity.domain[0]
  }

  moved {
    from = aws_sesv2_email_identity_mail_from_attributes.domain[0]
    to   = module.ses.aws_sesv2_email_identity_mail_from_attributes.domain[0]
  }

  moved {
    from = aws_sesv2_email_identity_feedback_attributes.domain[0]
    to   = module.ses.aws_sesv2_email_identity_feedback_attributes.domain[0]
  }

  moved {
    from = aws_sesv2_email_identity.recipient
    to   = module.ses.aws_sesv2_email_identity.recipient
  }
  ```

  A `moved` block on a `for_each` resource moves every instance, so the recipient loop needs no key.
- The tags the originals wrote were per resource (`${local.prefix}-ses-domain` on the identity,
  `${local.prefix}-transactional` on the set). This module writes one `tags` map to both, so an
  adopter that wants its old per resource `Name` tags back has to accept a tag-only diff or pass
  the set's tags and retag the identity outside the module. Tag drift is the one diff an otherwise
  empty adoption plan will show.
