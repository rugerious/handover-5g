# Public OIDC discovery for the k3s cluster, so AWS IAM can trust tokens that
# Kubernetes issues to service accounts (used by External Secrets, step 3.3).
#
# AWS must fetch two small public documents over HTTPS:
#   /.well-known/openid-configuration   who the issuer is, where the keys are
#   /openid/v1/jwks                     the cluster's PUBLIC signing key
#
# They live in a PRIVATE bucket. Only CloudFront can read it (Origin Access
# Control, signed requests); the bucket itself is never public. The issuer is
# the CloudFront address. The private key never leaves the node.

resource "aws_s3_bucket" "k3s_oidc" {
  bucket_prefix = "handover-k3s-oidc-" # AWS adds a random suffix
  force_destroy = true                 # only two public documents live here

  tags = { Name = "handover-k3s-oidc" }
}

resource "aws_s3_bucket_public_access_block" "k3s_oidc" {
  bucket                  = aws_s3_bucket.k3s_oidc.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "k3s_oidc" {
  bucket = aws_s3_bucket.k3s_oidc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CloudFront signs its requests to the bucket with its own identity.
resource "aws_cloudfront_origin_access_control" "k3s_oidc" {
  name                              = "handover-k3s-oidc"
  description                       = "CloudFront reads the k3s OIDC bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Never cache: if the key ever rotates, AWS sees the new one straight away.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

resource "aws_cloudfront_distribution" "k3s_oidc" {
  enabled         = true
  comment         = "handover k3s OIDC discovery"
  price_class     = "PriceClass_100" # Europe and North America edges only
  is_ipv6_enabled = true

  origin {
    origin_id                = "k3s-oidc-bucket"
    domain_name              = aws_s3_bucket.k3s_oidc.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.k3s_oidc.id
  }

  default_cache_behavior {
    target_origin_id       = "k3s-oidc-bucket"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_disabled.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # https://<id>.cloudfront.net
  }

  tags = { Name = "handover-k3s-oidc" }
}

# Only this distribution may read objects, and only over HTTPS.
data "aws_iam_policy_document" "k3s_oidc_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.k3s_oidc.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.k3s_oidc.arn]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.k3s_oidc.arn,
      "${aws_s3_bucket.k3s_oidc.arn}/*",
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

resource "aws_s3_bucket_policy" "k3s_oidc" {
  bucket = aws_s3_bucket.k3s_oidc.id
  policy = data.aws_iam_policy_document.k3s_oidc_bucket.json

  # The public access block must exist first, or AWS may reject the policy.
  depends_on = [aws_s3_bucket_public_access_block.k3s_oidc]
}

locals {
  k3s_oidc_issuer = "https://${aws_cloudfront_distribution.k3s_oidc.domain_name}"
}

resource "aws_s3_object" "k3s_oidc_discovery" {
  bucket       = aws_s3_bucket.k3s_oidc.id
  key          = ".well-known/openid-configuration"
  content_type = "application/json"
  content = jsonencode({
    issuer                                = local.k3s_oidc_issuer
    jwks_uri                              = "${local.k3s_oidc_issuer}/openid/v1/jwks"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
  })
}

# Public half of the k3s service-account signing key, read with
# `kubectl get --raw /openid/v1/jwks`. Safe to commit: no private parts.
resource "aws_s3_object" "k3s_oidc_jwks" {
  bucket       = aws_s3_bucket.k3s_oidc.id
  key          = "openid/v1/jwks"
  content_type = "application/json"
  content      = file("${path.module}/oidc/jwks.json")
}

output "k3s_oidc_issuer" {
  description = "Service-account issuer for k3s and the IAM OIDC provider (not secret)"
  value       = local.k3s_oidc_issuer
}
