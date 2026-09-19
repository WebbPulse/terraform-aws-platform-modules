locals {
  domain_identity_count = var.domain == null ? 0 : 1
  sender_identity_count = var.domain == null ? 1 : 0

  sending_identity_arn = var.domain == null ? aws_sesv2_email_identity.sender[0].arn : aws_sesv2_email_identity.domain[0].arn

  mail_from_count = var.domain != null && var.mail_from_domain != null ? 1 : 0
  feedback_count  = var.domain != null && var.set_feedback_attributes ? 1 : 0

  dkim_token_count  = 3
  dkim_record_count = var.domain != null && var.create_dkim_records ? local.dkim_token_count : 0
  dmarc_count       = var.domain != null && var.dmarc_record != null ? 1 : 0

  records_zone_id = coalesce(var.dkim_records_zone_id, "zone-id-unset")
}

resource "aws_sesv2_configuration_set" "this" {
  configuration_set_name = var.configuration_set_name

  reputation_options {
    reputation_metrics_enabled = var.reputation_metrics_enabled
  }

  sending_options {
    sending_enabled = var.sending_enabled
  }

  dynamic "delivery_options" {
    for_each = var.tls_policy == null ? [] : [var.tls_policy]

    content {
      tls_policy = delivery_options.value
    }
  }

  dynamic "vdm_options" {
    for_each = var.vdm_options_enabled ? [true] : []

    content {
      dashboard_options {
        engagement_metrics = "ENABLED"
      }
      guardian_options {
        optimized_shared_delivery = "ENABLED"
      }
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = (var.domain == null) != (var.sender_address == null)
      error_message = "Set exactly one of domain or sender_address."
    }

    precondition {
      condition     = !var.create_dkim_records || var.dkim_records_zone_id != null
      error_message = "create_dkim_records needs dkim_records_zone_id."
    }

    precondition {
      condition     = var.dmarc_record == null || var.dkim_records_zone_id != null
      error_message = "dmarc_record needs dkim_records_zone_id."
    }
  }
}

resource "aws_sesv2_email_identity" "domain" {
  count = local.domain_identity_count

  email_identity         = var.domain
  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name

  dkim_signing_attributes {
    next_signing_key_length = var.dkim_signing_key_length
  }

  tags = var.tags
}

resource "aws_sesv2_email_identity" "sender" {
  count = local.sender_identity_count

  email_identity         = var.sender_address
  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name

  tags = var.tags
}

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  count = local.mail_from_count

  email_identity         = aws_sesv2_email_identity.domain[0].email_identity
  mail_from_domain       = var.mail_from_domain
  behavior_on_mx_failure = var.behavior_on_mx_failure
}

resource "aws_sesv2_email_identity_feedback_attributes" "domain" {
  count = local.feedback_count

  email_identity           = aws_sesv2_email_identity.domain[0].email_identity
  email_forwarding_enabled = var.email_forwarding_enabled
}

resource "aws_sesv2_configuration_set_event_destination" "notifications" {
  count = var.notification_topic_arn == null ? 0 : 1

  configuration_set_name = aws_sesv2_configuration_set.this.configuration_set_name
  event_destination_name = var.event_destination_name

  event_destination {
    enabled              = true
    matching_event_types = var.notification_event_types

    sns_destination {
      topic_arn = var.notification_topic_arn
    }
  }
}

resource "aws_sesv2_account_vdm_attributes" "this" {
  count = var.manage_account_vdm_attributes ? 1 : 0

  vdm_enabled = "ENABLED"

  dashboard_attributes {
    engagement_metrics = "ENABLED"
  }

  guardian_attributes {
    optimized_shared_delivery = "ENABLED"
  }
}

resource "aws_sesv2_email_identity" "recipient" {
  for_each = toset(var.verified_recipients)

  email_identity = each.value

  tags = merge(var.tags, var.recipient_tags)
}
