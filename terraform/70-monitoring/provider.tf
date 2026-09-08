terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket         = "terrformlearn-remote-state"
    key            = "expense-dev-monitoring"
    region         = "us-east-1"
    dynamodb_table = "terrformlearn-locking"
  }
}

provider "aws" {
  region = "us-east-1"
}
