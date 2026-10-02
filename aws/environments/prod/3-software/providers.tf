terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "example-tfstate-storage"
    key            = "prod/software/terraform.tfstate"
    region         = "eu-south-2"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.platform.outputs.eks.endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.platform.outputs.eks.cert)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.platform.outputs.eks.name]
      command     = "aws"
    }
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.platform.outputs.eks.endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.platform.outputs.eks.cert)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.platform.outputs.eks.name]
    command     = "aws"
  }
}
