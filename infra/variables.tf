variable "region" {
  description = "AWS region for every Handover resource"
  type        = string
  default     = "eu-west-2"
}

# GitHub identity used in the OIDC trust policies (public information)
variable "github_owner" {
  description = "GitHub account that owns the repository"
  type        = string
  default     = "rugerious"
}

variable "github_repo" {
  description = "Repository name"
  type        = string
  default     = "handover-5g"
}

variable "github_owner_id" {
  description = "Numeric ID of the GitHub account (for ID-based OIDC subjects)"
  type        = string
  default     = "280082370"
}

variable "github_repo_id" {
  description = "Numeric ID of the repository (for ID-based OIDC subjects)"
  type        = string
  default     = "NNNN"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must be the numeric repository ID (gh api repos/OWNER/REPO --jq .id)."
  }
}
