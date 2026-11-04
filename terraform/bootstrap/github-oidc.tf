# Read-only role that GitHub Actions assumes through OIDC to run `terraform plan`.
# No access keys are stored in GitHub. The role can't create, change or delete anything.

variable "github_repository" {
  description = "owner/name of the repository allowed to assume the plan role. Empty skips the role."
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = "An account can have only one GitHub OIDC provider. Set to false if it already exists."
  type        = bool
  default     = true
}

locals {
  plan_role = var.github_repository != ""
  oidc_url  = "token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = local.plan_role && var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_url}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "plan_trust" {
  count = local.plan_role ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_url}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Pull requests in this repository and manual runs on main. Forks never get an OIDC token for it.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_url}:sub"
      values = [
        "repo:${var.github_repository}:pull_request",
        "repo:${var.github_repository}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  count                = local.plan_role ? 1 : 0
  name                 = "github-terraform-plan"
  description          = "Read-only: terraform plan from GitHub Actions"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust[0].json
  max_session_duration = 3600
  depends_on           = [aws_iam_openid_connect_provider.github]
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  count      = local.plan_role ? 1 : 0
  role       = aws_iam_role.plan[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable."
  value       = one(aws_iam_role.plan[*].arn)
}
