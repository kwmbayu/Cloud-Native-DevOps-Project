terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket = "terrformlearn-remote-state"
    key    = "expense-dev-acm-p"
    region = "us-east-1"
    use_lockfile = true
  }
}

#provide authentication here
provider "aws" {
  region = "us-east-1"
}