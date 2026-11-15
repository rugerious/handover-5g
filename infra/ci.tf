# GitHub Actions -> AWS through OIDC: short-lived credentials, no stored keys.
#
# BOOTSTRAP FILE: apply changes to this file from CloudShell, never from CI.
# CI cannot fix its own trust (CloudOps lesson), and the apply role is not
# allowed to modify the handover-github-* roles (see DenySelfModification).

# One GitHub OIDC provider per AWS account. CloudOps created it (its ci.tf);
# Handover only reads it. Never declare a second aws_iam_openid_connect_provider.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  state_bucket = "handover-tfstate-09f425"
  state_key    = "handover/terraform.tfstate"
  account_id   = data.aws_caller_identity.current.account_id

  # GitHub may send the classic name-based subject or the newer ID-based one
  # (CloudOps bug 28). Trust both.
  repo_subjects = [
    "repo:${var.github_owner}/${var.github_repo}",
    "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}",
  ]
}

# ---------------------------------------------------------------------------
# Plan role: pull requests only, read-only
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "trust_plan" {
  statement {
    sid     = "GitHubPullRequests"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for s in local.repo_subjects : "${s}:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "handover-github-plan"
  description          = "GitHub Actions on pull requests: terraform plan (read-only)"
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_extra" {
  # plan needs to take and release the S3 state lock
  statement {
    sid       = "StateLockFile"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/${local.state_key}.tflock"]
  }

  # ReadOnlyAccess can read every S3 object in the account (CloudOps state,
  # incident photos...). A pull-request job only needs the Handover state,
  # plus the k3s OIDC documents (public anyway, via CloudFront) to refresh them.
  statement {
    sid     = "DenyReadingOtherObjects"
    effect  = "Deny"
    actions = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = [
      "arn:aws:s3:::${local.state_bucket}/*",
      "arn:aws:s3:::handover-k3s-oidc-*/*",
    ]
  }
}

resource "aws_iam_role_policy" "plan_extra" {
  name   = "handover-plan-extra"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.plan_extra.json
}

# ---------------------------------------------------------------------------
# Apply role: only jobs running in the protected "production" environment
# (main branch, approved by a reviewer)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "trust_apply" {
  statement {
    sid     = "GitHubProductionEnvironment"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for s in local.repo_subjects : "${s}:environment:production"]
    }
  }
}

resource "aws_iam_role" "github_apply" {
  name                 = "handover-github-apply"
  description          = "GitHub Actions on main (production environment): terraform apply"
  assume_role_policy   = data.aws_iam_policy_document.trust_apply.json
  max_session_duration = 3600
}

# Everything except IAM and Organizations
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.github_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_iam" {
  # Read IAM to plan and refresh
  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Manage only Handover's own roles, instance profiles and policies
  statement {
    sid = "ManageHandoverIam"
    actions = [
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:role/handover-*",
      "arn:aws:iam::${local.account_id}:instance-profile/handover-*",
      "arn:aws:iam::${local.account_id}:policy/handover-*",
    ]
  }

  # Giving a role permissions is allowed only if the role carries the workload
  # boundary (below). So CI can never create a role more powerful than the
  # boundary allows, whatever policy it attaches.
  statement {
    sid = "GrantOnlyInsideTheBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/handover-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  # CI can neither remove the boundary from a role nor change the boundary itself.
  statement {
    sid       = "KeepTheBoundaryOnRoles"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account_id}:role/handover-*"]
  }

  statement {
    sid    = "KeepTheBoundaryPolicy"
    effect = "Deny"
    actions = [
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:DeletePolicy",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = [aws_iam_policy.workload_boundary.arn]
  }

  # Manage only the k3s cluster's OIDC provider (infra/eso.tf), never the
  # GitHub one that this pipeline itself depends on.
  statement {
    sid = "ManageK3sOidcProvider"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:iam::${local.account_id}:oidc-provider/${aws_cloudfront_distribution.k3s_oidc.domain_name}",
    ]
  }

  # The pipeline must never be able to widen its own permissions.
  # Reading these roles stays allowed (refresh needs it); changing them is
  # bootstrap-only, from CloudShell.
  statement {
    sid    = "DenySelfModification"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/handover-github-*"]
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  name   = "handover-apply-iam"
  role   = aws_iam_role.github_apply.id
  policy = data.aws_iam_policy_document.apply_iam.json
}

# ---------------------------------------------------------------------------
# Permissions boundary for every role the pipeline creates (MVP hardening)
# ---------------------------------------------------------------------------
# Without it, the apply role (PowerUser + IAM on handover-*) could create a
# handover-* role, attach AdministratorAccess and assume it: from "can deploy"
# to "owns the account". A boundary is a ceiling: whatever policy is attached,
# the role can never do more than this. Every workload role carries it, and
# the apply role may only create or empower roles that do (GrantOnlyInsideTheBoundary).
# It caps the roles at what the pipeline itself can already do, minus identity
# and account control. Changing it is bootstrap-only (KeepTheBoundaryPolicy).
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid       = "AllowServiceWork"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid    = "NoIdentityOrAccountControl"
    effect = "Deny"
    actions = [
      "iam:*",
      "organizations:*",
      "account:*",
      "sts:AssumeRole",
      "sts:AssumeRoleWithSAML",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "handover-workload-boundary"
  description = "Ceiling for every Handover workload role: no IAM, Organizations, account or role chaining"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# ---------------------------------------------------------------------------
# Outputs: role ARNs go into GitHub secrets (they contain the account ID)
# ---------------------------------------------------------------------------

output "github_plan_role_arn" {
  description = "Role for terraform plan on pull requests"
  value       = aws_iam_role.github_plan.arn
  sensitive   = true
}

output "github_apply_role_arn" {
  description = "Role for terraform apply on main (production environment)"
  value       = aws_iam_role.github_apply.arn
  sensitive   = true
}
