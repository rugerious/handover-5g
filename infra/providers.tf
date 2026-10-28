provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "handover"
      Environment = "lab"
      ManagedBy   = "terraform"
      Repo        = "rugerious/handover-5g"
    }
  }
}

data "aws_caller_identity" "current" {}

output "account_id" {
  description = "AWS account this state belongs to"
  value       = data.aws_caller_identity.current.account_id
  sensitive   = true
}
