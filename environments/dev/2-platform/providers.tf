terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    # ─── AGREGAMOS EL PROVEEDOR DE INFRAESTRUCTURA DE ESCALADO ───
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
  }

  backend "s3" {
    bucket         = "example-tfstate-storage"
    key            = "dev/platform/terraform.tfstate"
    region         = "eu-south-2"
    use_lockfile = true # <--- Reemplaza dynamodb_table on Terraform (v1.11+)
    #dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = module.platform.eks.endpoint
  cluster_ca_certificate = base64decode(module.platform.eks.cert)
  #alias = aws_eks
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.platform.eks.name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.platform.eks.endpoint
    cluster_ca_certificate = base64decode(module.platform.eks.cert)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.platform.eks.name]
    }
  }
}

provider "kubectl" {
  host                   = module.platform.eks.endpoint
  cluster_ca_certificate = base64decode(module.platform.eks.cert)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.platform.eks.name]
  }
}
