# AWS trusts the k3s cluster (step 3.3b), so External Secrets can read the
# lab's secrets from SSM Parameter Store instead of keeping them in Git.
#
# Flow: External Secrets asks Kubernetes for a short-lived token for ONE
# service account, sends it to AWS STS, and gets 1-hour credentials for the
# handover-eso role. AWS checks the token's signature against the public key
# published by infra/oidc.tf. No access keys are stored anywhere.

locals {
  k3s_oidc_host = aws_cloudfront_distribution.k3s_oidc.domain_name

  # The only Kubernetes identity allowed to use the role.
  eso_namespace       = "external-secrets"
  eso_service_account = "handover-ssm-reader"
}

resource "aws_iam_openid_connect_provider" "k3s" {
  url            = local.k3s_oidc_issuer
  client_id_list = ["sts.amazonaws.com"] # tokens must be made for AWS STS

  tags = { Name = "handover-k3s" }
}

data "aws_iam_policy_document" "eso_trust" {
  statement {
    sid     = "K3sServiceAccount"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.k3s.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.k3s_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.k3s_oidc_host}:sub"
      values   = ["system:serviceaccount:${local.eso_namespace}:${local.eso_service_account}"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name                 = "handover-eso"
  description          = "External Secrets on k3s: read /handover/* from SSM Parameter Store"
  assume_role_policy   = data.aws_iam_policy_document.eso_trust.json
  max_session_duration = 3600
}

# Read-only, and only the lab's own parameters.
data "aws_iam_policy_document" "eso_read" {
  statement {
    sid = "ReadHandoverParameters"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${var.region}:${local.account_id}:parameter/handover/*",
    ]
  }

  # SecureString values are encrypted with the AWS-managed SSM key; decrypting
  # is allowed only when the request comes through SSM in this region.
  statement {
    sid       = "DecryptViaSsmOnly"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "eso_read" {
  name   = "handover-eso-read"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_read.json
}

output "eso_role_arn" {
  description = "Role for External Secrets (contains the account ID)"
  value       = aws_iam_role.eso.arn
  sensitive   = true
}
