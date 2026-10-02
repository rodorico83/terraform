terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "example-tfstate-storage"
    key            = "dev/network/terraform.tfstate"
    region         = "eu-south-2"
    use_lockfile = true # <--- Reemplaza dynamodb_table on Terraform (v1.11+)
    #dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
