# The lab node: one x86 EC2 instance, reachable ONLY through SSM Session
# Manager (no SSH key, no inbound port), stopped automatically every night.

variable "instance_type" {
  description = "x86 size for the lab node (4 vCPU / 16 GiB; revisit at step 5.1 multi-UE)"
  type        = string
  default     = "m7i.xlarge"
}

# Latest Ubuntu 24.04 LTS (amd64, gp3) published by Canonical, via the public
# SSM parameter: no hard-coded AMI ID.
data "aws_ssm_parameter" "ubuntu_2404" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ---------------------------------------------------------------------------
# Instance role: only what SSM Session Manager needs
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "instance_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "handover-instance"
  description        = "Lab node: SSM Session Manager only"
  assume_role_policy = data.aws_iam_policy_document.instance_trust.json
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "handover-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_instance" "node" {
  ami                         = data.aws_ssm_parameter.ubuntu_2404.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  associate_public_ip_address = true # outbound internet without a NAT gateway
  iam_instance_profile        = aws_iam_instance_profile.instance.name

  # IMDSv2 only (blocks the classic SSRF credential theft). Hop limit 1: pods
  # inside k3s cannot reach the instance's credentials. Revisit at step 3.4.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 40
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "handover-node-1" }

  lifecycle {
    # Canonical publishes a new AMI every few weeks. Without this, Terraform
    # would want to REPLACE the instance (and wipe the lab) each time.
    # Upgrades happen on purpose, not as a side effect.
    ignore_changes = [ami]
  }
}

# ---------------------------------------------------------------------------
# Cost guard rail: stop the instance every night at 23:00 London time
# (EventBridge Scheduler calls EC2 StopInstances directly, no Lambda)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler_stop" {
  name               = "handover-scheduler-stop"
  description        = "Lets EventBridge Scheduler stop the lab node at night"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler_stop" {
  statement {
    actions   = ["ec2:StopInstances"]
    resources = [aws_instance.node.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_stop" {
  name   = "handover-stop-node"
  role   = aws_iam_role.scheduler_stop.id
  policy = data.aws_iam_policy_document.scheduler_stop.json
}

resource "aws_scheduler_schedule" "nightly_stop" {
  name                         = "handover-nightly-stop"
  description                  = "Stop the Handover lab node every night (cost guard rail)"
  schedule_expression          = "cron(0 23 * * ? *)"
  schedule_expression_timezone = "Europe/London"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler_stop.arn
    input    = jsonencode({ InstanceIds = [aws_instance.node.id] })
  }
}

# ---------------------------------------------------------------------------
# Outputs (not secret)
# ---------------------------------------------------------------------------

output "node_instance_id" {
  value = aws_instance.node.id
}

output "node_ami" {
  description = "AMI the node was launched from"
  value       = aws_instance.node.ami
}
