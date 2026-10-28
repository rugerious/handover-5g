terraform {
  backend "s3" {
    bucket       = "handover-tfstate-09f425"
    key          = "handover/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
