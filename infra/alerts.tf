# Phase 4.5: alert delivery. Alertmanager (in k3s) publishes the lab's alerts to
# one SNS topic; the topic emails them. No password or access key anywhere:
#
#   Alertmanager pod --(its own service-account token)--> AWS STS
#     --> 1-hour credentials for handover-alertmanager --> sns:Publish, this topic only
#
# Same trust as External Secrets (infra/eso.tf). Pods cannot use the node's role
# (IMDS hop limit 1, infra/compute.tf), so Alertmanager gets an identity of its own.
#
# The topic and role ARNs contain the account ID, so they are not written in Git:
# they go to SSM Parameter Store and reach the cluster through External Secrets.
# The email address is not in Git either: subscribed once by CLI (docs/runbook.md).

locals {
  alertmanager_namespace       = "monitoring"
  alertmanager_service_account = "kps-alertmanager" # created by kube-prometheus-stack
}

resource "aws_sns_topic" "alerts" {
  name              = "handover-alerts"
  kms_master_key_id = "alias/aws/sns" # encrypted at rest with the AWS-managed key

  tags = { Name = "handover-alerts" }
}

data "aws_iam_policy_document" "alertmanager_trust" {
  statement {
    sid     = "K3sAlertmanager"
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
      values   = ["system:serviceaccount:${local.alertmanager_namespace}:${local.alertmanager_service_account}"]
    }
  }
}

resource "aws_iam_role" "alertmanager" {
  name                 = "handover-alertmanager"
  description          = "Alertmanager on k3s: publish to the handover-alerts SNS topic only"
  assume_role_policy   = data.aws_iam_policy_document.alertmanager_trust.json
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.workload_boundary.arn
}

data "aws_iam_policy_document" "alertmanager_publish" {
  statement {
    sid       = "PublishLabAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "alertmanager_publish" {
  name   = "handover-alertmanager-publish"
  role   = aws_iam_role.alertmanager.id
  policy = data.aws_iam_policy_document.alertmanager_publish.json
}

# Identifiers, not secrets, but they contain the account ID: kept out of Git.
resource "aws_ssm_parameter" "alerts_topic_arn" {
  name        = "/handover/alerts/topic-arn"
  description = "SNS topic for lab alerts (read by External Secrets for Alertmanager)"
  type        = "String"
  value       = aws_sns_topic.alerts.arn
}

resource "aws_ssm_parameter" "alertmanager_role_arn" {
  name        = "/handover/alerts/alertmanager-role-arn"
  description = "IAM role Alertmanager assumes with its service-account token"
  type        = "String"
  value       = aws_iam_role.alertmanager.arn
}
