resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = local.repository_names[each.key]
  image_tag_mutability = coalesce(each.value.image_tag_mutability, var.image_tag_mutability)
  force_delete         = coalesce(each.value.force_delete, var.force_delete)

  image_scanning_configuration {
    scan_on_push = coalesce(each.value.scan_on_push, var.scan_on_push)
  }

  encryption_configuration {
    encryption_type = var.encryption_type
    kms_key         = var.encryption_type == "AES256" ? null : var.encryption_kms_key
  }

  tags = length(local.repository_tags[each.key]) == 0 ? null : local.repository_tags[each.key]
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = local.lifecycle_policies

  repository = aws_ecr_repository.this[each.key].name
  policy     = each.value
}

resource "aws_ecr_repository_policy" "this" {
  for_each = local.repository_policy_keys

  repository = aws_ecr_repository.this[each.key].name
  policy     = coalesce(var.repository_policy_json, data.aws_iam_policy_document.cross_account_pull.json)
}

data "aws_iam_policy_document" "cross_account_pull" {
  statement {
    sid = "CrossAccountPull"

    principals {
      type        = "AWS"
      identifiers = length(var.repository_policy_principals) > 0 ? var.repository_policy_principals : ["*"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
  }

  statement {
    sid = "LambdaCrossAccountImageRetrieval"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]

    condition {
      test     = "ArnLike"
      variable = "aws:sourceARN"
      values   = [for arn in var.repository_policy_principals : "arn:aws:lambda:*:${split(":", arn)[4]}:function:*"]
    }
  }
}
