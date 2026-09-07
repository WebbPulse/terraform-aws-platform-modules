resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = local.repository_names[each.key]
  image_tag_mutability = coalesce(each.value.image_tag_mutability, var.image_tag_mutability)
  force_delete         = coalesce(each.value.force_delete, var.force_delete)

  image_scanning_configuration {
    scan_on_push = coalesce(each.value.scan_on_push, var.scan_on_push)
  }

  # Encryption is fixed at creation, so changing either input replaces the repository. kms_key is
  # left null under AES256, which is what a repository created without one stores.
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

# The cross-account pull policy the module builds when repository_policy_principals is set. It is
# evaluated even when no repository uses it, which costs nothing: a policy document data source
# makes no API call.
data "aws_iam_policy_document" "cross_account_pull" {
  # Lets the named accounts pull, and create or update a function from, an image in this
  # repository. Cross-account access needs both sides to allow the action, so this is the half the
  # repository owner writes; the consuming account still grants the same actions on its own role.
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

  # Lambda re-fetches a container image on its own behalf, to optimise and cache it and to bring a
  # function back from Inactive. Without this statement a cross-account container-image function
  # deploys and then fails later, which is the failure mode worth spending a statement to avoid.
  # The source-ARN condition keeps the grant to functions in the accounts named above.
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
