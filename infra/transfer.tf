# S3 bucket that Ansible's amazon.aws.aws_ssm connection uses to move files
# (including its own module code) to and from the node. No SSH anywhere.
#
# The laptop uploads; the node downloads with a short-lived presigned URL, so
# the node's IAM role needs NO S3 permissions. Objects are temporary: no
# versioning (old copies would linger) and everything expires after 1 day.

resource "aws_s3_bucket" "ssm_transfer" {
  bucket_prefix = "handover-ssm-transfer-" # AWS adds a random suffix
  force_destroy = true                     # only temporary files live here

  tags = { Name = "handover-ssm-transfer" }
}

resource "aws_s3_bucket_public_access_block" "ssm_transfer" {
  bucket                  = aws_s3_bucket.ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id

  rule {
    id     = "expire-transfers"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Refuse anything that is not HTTPS.
data "aws_iam_policy_document" "ssm_transfer_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.ssm_transfer.arn,
      "${aws_s3_bucket.ssm_transfer.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id
  policy = data.aws_iam_policy_document.ssm_transfer_tls_only.json

  # The public access block must exist first, or AWS may reject the policy.
  depends_on = [aws_s3_bucket_public_access_block.ssm_transfer]
}

output "ssm_transfer_bucket" {
  description = "Bucket for Ansible's aws_ssm connection (not secret)"
  value       = aws_s3_bucket.ssm_transfer.bucket
}
