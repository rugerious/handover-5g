# Network for the Handover lab: one VPC, one public subnet, no NAT gateway.
#
# Why no NAT: a NAT gateway costs ~$35/month even when the instance is stopped
# (more than the whole budget). The instance gets a public IP instead, but its
# security group has ZERO inbound rules: nothing on the internet can open a
# connection to it. Shell access is through SSM Session Manager (outbound only).

locals {
  az = "${var.region}a"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "handover-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "handover-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.50.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = false # the instance asks for its own public IP explicitly

  tags = { Name = "handover-public-${local.az}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "handover-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# The VPC's default security group allows all traffic between its members.
# Take it over and leave it with no rules, so nothing can use it by accident.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "handover-default-sg-locked" }
}

# The instance's security group: NO inbound rules at all.
resource "aws_security_group" "instance" {
  name        = "handover-instance-sg"
  description = "Handover lab instance: no inbound, outbound web only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "handover-instance-sg" }
}

# Outbound: HTTPS (SSM, AWS APIs, GHCR, k3s, Helm charts) and HTTP (Ubuntu
# package mirrors). Nothing else. DNS and time sync use AWS-provided services
# inside the VPC, which security groups do not filter.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.instance.id
  description       = "HTTPS out"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.instance.id
  description       = "HTTP out (Ubuntu package mirrors)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# VPC flow logs: record REJECTED traffic (the scanners bouncing off), 14 days
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/handover/vpc-flow-logs"
  retention_in_days = 14
}

data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "handover-vpc-flow-logs"
  description        = "Lets VPC Flow Logs write to the handover log group"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust.json
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "handover-vpc-flow-logs-write"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "rejects" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "REJECT"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 600

  tags = { Name = "handover-vpc-rejects" }
}

# ---------------------------------------------------------------------------
# Outputs (not secret)
# ---------------------------------------------------------------------------

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "instance_security_group_id" {
  value = aws_security_group.instance.id
}
