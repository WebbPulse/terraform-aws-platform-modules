variables {
  name_prefix = "example-staging"

  repositories = {
    content  = {}
    identity = {}
  }
}

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

run "no_repository_policy_is_created_for_the_ordinary_same_account_case" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository_policy.this) == 0
    error_message = "With no principals and no explicit document there must be no repository policy at all. Same account access needs only the caller's side to allow it, and Lambda adds its own retrieval statement to the repository when a function is created, so a policy here would be noise that Lambda then has to edit around."
  }

  assert {
    condition     = local.create_repository_policy == false
    error_message = "The module must decide not to create a policy rather than creating an empty one; an ECR repository policy with no statements is rejected."
  }

  assert {
    condition     = length(local.repository_policy_keys) == 0
    error_message = "With no policy to write, the key map the policy resource iterates must be empty."
  }
}

run "principals_create_one_policy_per_repository_with_both_statements" {
  command = plan

  variables {
    repository_policy_principals = ["arn:aws:iam::123456789012:root"]
  }

  assert {
    condition     = length(aws_ecr_repository_policy.this) == 2
    error_message = "A cross account grant must be written onto every repository in the module block, because a repository policy is per repository and a consumer pulling one domain image usually pulls them all."
  }

  assert {
    condition     = length(jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement) == 2
    error_message = "The generated policy must hold both statements: the pull grant to the named principals, and the grant that lets the Lambda service itself retrieve the image on behalf of a function in one of those accounts."
  }

  assert {
    condition     = [for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Sid] == ["CrossAccountPull", "LambdaCrossAccountImageRetrieval"]
    error_message = "Both statements must carry their sids, which is the only way a reader of the repository policy can tell the direct pull grant from the Lambda service grant."
  }
}

run "the_pull_statement_grants_exactly_the_three_actions_a_pull_needs" {
  command = plan

  variables {
    repository_policy_principals = ["arn:aws:iam::123456789012:root"]
  }

  assert {
    condition = sort(one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Action if s.Sid == "CrossAccountPull"
      ])) == tolist([
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ])
    error_message = "The pull statement must grant exactly BatchGetImage, DescribeImages and GetDownloadUrlForLayer, and nothing else. Those three are what reading an image takes, and adding a push action here would let a foreign account overwrite this estate's images."
  }

  assert {
    condition = !anytrue([
      for a in one([
        for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Action if s.Sid == "CrossAccountPull"
      ]) : startswith(a, "ecr:Put") || startswith(a, "ecr:Delete") || startswith(a, "ecr:InitiateLayerUpload")
    ])
    error_message = "The cross account statement must never grant a write action. This policy is the one place a principal outside the account is named, so a push or delete action in it is a foreign account able to replace a production image."
  }

  assert {
    condition = one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Effect if s.Sid == "CrossAccountPull"
    ]) == "Allow"
    error_message = "The pull statement must be an Allow; a repository policy exists only to add access that the resource owner has not otherwise granted."
  }

  assert {
    condition = one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Principal.AWS if s.Sid == "CrossAccountPull"
    ]) == "arn:aws:iam::123456789012:root"
    error_message = "The named principal must reach the statement. AWS requires both sides to allow a cross account pull, so a principal that fails to land here leaves the puller denied no matter what its own policy says."
  }
}

run "the_lambda_statement_is_scoped_to_functions_in_the_named_accounts" {
  command = plan

  variables {
    repository_policy_principals = ["arn:aws:iam::123456789012:root"]
  }

  assert {
    condition = one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Principal.Service if s.Sid == "LambdaCrossAccountImageRetrieval"
    ]) == "lambda.amazonaws.com"
    error_message = "The second statement's principal must be the Lambda service. A container image Lambda re-optimises the image outside the invoking principal's context, so without a service grant the function breaks later rather than at deploy time."
  }

  assert {
    condition = one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Condition.ArnLike["aws:sourceARN"] if s.Sid == "LambdaCrossAccountImageRetrieval"
    ]) == "arn:aws:lambda:*:123456789012:function:*"
    error_message = "The Lambda grant must be conditioned on a source ARN built from the account in each principal ARN, so the service grant reaches only functions in the accounts the caller actually named rather than every Lambda function in the partition."
  }

  assert {
    condition = sort(one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Action if s.Sid == "LambdaCrossAccountImageRetrieval"
      ])) == tolist([
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ])
    error_message = "The Lambda service grant needs only BatchGetImage and GetDownloadUrlForLayer to retrieve an image; DescribeImages is a caller convenience the service does not need."
  }
}

run "several_principals_each_get_a_pull_grant_and_a_scoped_lambda_condition" {
  command = plan

  variables {
    repository_policy_principals = [
      "arn:aws:iam::123456789012:root",
      "arn:aws:iam::210987654321:role/example-staging-deploy",
    ]
  }

  assert {
    condition = length(one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Principal.AWS if s.Sid == "CrossAccountPull"
    ])) == 2
    error_message = "Every named principal must appear in the pull statement, so one repository can serve several consuming accounts from a single policy."
  }

  assert {
    condition = length(one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Condition.ArnLike["aws:sourceARN"] if s.Sid == "LambdaCrossAccountImageRetrieval"
    ])) == 2
    error_message = "The Lambda condition must carry one source ARN pattern per principal. A missing pattern leaves that account's functions unable to re-optimise the image, which surfaces as a function that deploys and then fails to start."
  }

  assert {
    condition = contains(one([
      for s in jsondecode(data.aws_iam_policy_document.cross_account_pull.json).Statement : s.Condition.ArnLike["aws:sourceARN"] if s.Sid == "LambdaCrossAccountImageRetrieval"
    ]), "arn:aws:lambda:*:210987654321:function:*")
    error_message = "The account id must be taken from the fifth field of each principal ARN, so a role ARN yields the same source pattern an account root would."
  }
}

run "an_explicit_policy_document_replaces_the_generated_one" {
  command = plan

  variables {
    repository_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid       = "OrgWidePull"
          Effect    = "Allow"
          Principal = "*"
          Action    = ["ecr:BatchGetImage"]
          Condition = {
            StringEquals = {
              "aws:PrincipalOrgID" = "o-exampleorgid"
            }
          }
        },
      ]
    })
  }

  assert {
    condition     = length(aws_ecr_repository_policy.this) == 2
    error_message = "An explicit document must be enough on its own to create the policy on every repository, without also having to name principals."
  }

  assert {
    condition     = local.create_repository_policy == true
    error_message = "Supplying a document alone must switch policy creation on, since it is the escape hatch for a policy the generated statements cannot express, such as an organisation wide condition."
  }

  assert {
    condition     = one(distinct([for p in aws_ecr_repository_policy.this : jsondecode(p.policy).Statement[0].Sid])) == "OrgWidePull"
    error_message = "The explicit document must be written verbatim to every repository, replacing the generated one rather than being merged with it."
  }

  assert {
    condition = alltrue([
      for p in aws_ecr_repository_policy.this : length(jsondecode(p.policy).Statement) == 1
    ])
    error_message = "The explicit document must be the whole policy: if the generated statements were appended, the caller's carefully scoped document would silently be widened."
  }
}

run "the_policy_is_attached_to_each_repository_by_name" {
  command = plan

  variables {
    repository_policy_principals = ["arn:aws:iam::123456789012:root"]
  }

  assert {
    condition     = aws_ecr_repository_policy.this["content"].repository == "example-staging/content"
    error_message = "The policy must address its repository by the full prefixed name. ECR takes a repositoryName rather than an ARN on this call, so addressing it by the short key would target a repository that does not exist."
  }

  assert {
    condition     = aws_ecr_lifecycle_policy.this["content"].repository == "example-staging/content"
    error_message = "The lifecycle policy must address its repository by the same full name, for the same reason."
  }
}

run "the_guard_against_setting_both_a_document_and_principals_stays_satisfied" {
  command = plan

  variables {
    repository_policy_json = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid       = "OrgWidePull"
          Effect    = "Allow"
          Principal = "*"
          Action    = ["ecr:BatchGetImage"]
        },
      ]
    })
  }

  assert {
    condition     = local.validate_policy_inputs == true
    error_message = "Supplying only a document must leave the guard satisfied. The guard exists because repository_policy_json already replaces the generated policy, so setting principals alongside it means one of the two inputs is silently ignored; it fires as a plan error rather than a variable validation because it spans two variables."
  }

  assert {
    condition     = one(distinct([for p in aws_ecr_repository_policy.this : jsondecode(p.policy).Statement[0].Sid])) == "OrgWidePull"
    error_message = "With the guard satisfied the explicit document must be the policy that is written, confirming the document is what wins when it is the only one of the two inputs set."
  }
}

run "a_principal_that_is_not_an_iam_principal_arn_is_rejected" {
  command = plan

  variables {
    repository_policy_principals = ["123456789012"]
  }

  expect_failures = [var.repository_policy_principals]
}

run "a_service_principal_in_place_of_an_iam_principal_arn_is_rejected" {
  command = plan

  variables {
    repository_policy_principals = ["lambda.amazonaws.com"]
  }

  expect_failures = [var.repository_policy_principals]
}

run "a_repeated_principal_is_rejected" {
  command = plan

  variables {
    repository_policy_principals = [
      "arn:aws:iam::123456789012:root",
      "arn:aws:iam::123456789012:root",
    ]
  }

  expect_failures = [var.repository_policy_principals]
}

run "a_repository_policy_document_that_is_not_valid_json_is_rejected" {
  command = plan

  variables {
    repository_policy_json = "not json at all"
  }

  expect_failures = [var.repository_policy_json]
}
